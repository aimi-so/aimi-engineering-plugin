#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.
# Operates on v3 task schema exclusively.

AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"

# ============================================================================
# Utility Functions
# ============================================================================

# Detect platform capabilities once at startup
_HAS_FLOCK=$(command -v flock &>/dev/null && echo 1 || echo 0)
_HAS_REALPATH=$(command -v realpath &>/dev/null && echo 1 || echo 0)
_HAS_SHA256SUM=$(command -v sha256sum &>/dev/null && echo 1 || echo 0)

# Resolve a path to its absolute form (POSIX-compatible)
resolve_path() {
  local path="$1"
  if [ "$_HAS_REALPATH" -eq 1 ]; then
    realpath "$path"
  else
    (cd "$(dirname "$path")" && echo "$(pwd)/$(basename "$path")")
  fi
}

# Auto-discover the project root containing .aimi/ by walking up the directory tree.
# On success: cd to the discovered root, rewrite AIMI_DIR and TASKS_DIR to absolute paths,
#             and export PROJECT_ROOT for use by other functions.
# On failure (reached /): exit 1 with error to stderr.
find_aimi_root() {
  local dir
  dir=$(pwd)
  while true; do
    if [ -d "$dir/.aimi" ]; then
      cd "$dir"
      AIMI_DIR="$dir/.aimi"
      TASKS_DIR="$AIMI_DIR/tasks"

      # Discover the git repository root and export as PROJECT_ROOT
      local git_root
      git_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || git_root="$dir"
      PROJECT_ROOT=$(resolve_path "$git_root")
      export PROJECT_ROOT

      return 0
    fi
    # Stop at HOME — never scan above the user's home directory
    if [ "$dir" = "$HOME" ]; then
      echo "Error: .aimi/ directory not found (searched up to \$HOME)" >&2
      exit 1
    fi
    local parent
    parent=$(dirname "$dir")
    if [ "$parent" = "$dir" ]; then
      # Reached filesystem root without finding .aimi/
      echo "Error: .aimi/ directory not found in any parent directory" >&2
      exit 1
    fi
    dir="$parent"
  done
}

# Validate that a given path resolves to a location within PROJECT_ROOT.
# Worktree paths (under .worktrees/ inside PROJECT_ROOT) are explicitly allowed.
# Usage: validate_path_in_project "/some/path"
# Returns 0 if path is within PROJECT_ROOT, exits with error otherwise.
validate_path_in_project() {
  local target_path="$1"

  if [ -z "$target_path" ]; then
    echo "Error: validate_path_in_project requires a path argument" >&2
    exit 1
  fi

  if [ -z "$PROJECT_ROOT" ]; then
    echo "Error: PROJECT_ROOT is not set — call find_aimi_root() first" >&2
    exit 1
  fi

  # Resolve the target path to its absolute form
  local resolved_target
  if [ -e "$target_path" ]; then
    resolved_target=$(resolve_path "$target_path")
  else
    # For paths that don't exist yet, resolve the parent directory
    local parent_dir
    parent_dir=$(dirname "$target_path")
    if [ -e "$parent_dir" ]; then
      resolved_target="$(resolve_path "$parent_dir")/$(basename "$target_path")"
    else
      resolved_target="$target_path"
    fi
  fi

  # Check if the resolved path is under PROJECT_ROOT
  case "$resolved_target" in
    "$PROJECT_ROOT"/*) return 0 ;;  # Under project root (includes .worktrees/)
    "$PROJECT_ROOT")   return 0 ;;  # Exactly the project root
    *)
      echo "Error: Path escapes project root — access denied" >&2
      echo "  Path:         $resolved_target" >&2
      echo "  Project root: $PROJECT_ROOT" >&2
      exit 1
      ;;
  esac
}

# Portable exclusive lock (Linux: flock, macOS: mkdir spinlock)
# Usage: call inside a subshell with FD 200 redirect:
#   (_lock "lockfile"; ... ) 200>"lockfile"
# Linux: flock acquires lock on FD 200, auto-releases when subshell exits
# macOS: mkdir creates atomic lock dir, trap EXIT cleans up on subshell exit
_lock() {
  if [ "$_HAS_FLOCK" -eq 1 ]; then
    flock -x 200
  else
    local lockdir="$1.d"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 0.05
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 200 ]; then
        echo "Warning: Breaking stale lock on $1" >&2
        rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir"
        attempts=0
      fi
    done
    trap "rmdir '$lockdir' 2>/dev/null" EXIT
  fi
}

# Ensure jq is available
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
  fi
}

# Ensure python3 is available. Mirrors check_jq, and is called by the roadmap
# verbs only -- every other verb in this file is pure bash + jq and must keep
# working on a host without python3.
check_python3() {
  if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required by the roadmap verbs but is not installed." >&2
    echo "Install with: brew install python (macOS) or apt install python3 (Linux)" >&2
    exit 1
  fi
}

# Absolute path to roadmap.py, which sits beside this script.
#
# Same ${BASH_SOURCE[0]:-$0} idiom cmd_version already uses to find plugin.json
# one directory up. It has to be resolved rather than assumed because this file
# is invoked through a cached path, through $AIMI_PLUGIN_DIR, and from a
# worktree, and only its own location is reliable in all three.
_aimi_roadmap_py() {
  local script_path
  script_path="${BASH_SOURCE[0]:-$0}"
  printf '%s/roadmap.py\n' "$(cd "$(dirname "$script_path")" && pwd)"
}

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$AIMI_DIR"
}

# Read a state file, returns empty string if not exists
read_state() {
  local key="$1"
  local file="$AIMI_DIR/$key"
  validate_path_in_project "$file"
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

# Write a value to a state file (flock-protected for parallel safety)
write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    echo "$value" > "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Clear a single state file (flock-protected for parallel safety)
clear_state_file() {
  local key="$1"
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    rm -f "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Extract version string from an aimi-cli.sh path
# Given: <config_dir>/plugins/cache/foo/aimi-engineering/1.4.0/scripts/aimi-cli.sh
# Returns: 1.4.0
_extract_version_from_path() {
  local path="$1"
  local no_script="${path%/*}"       # strip /aimi-cli.sh -> .../scripts
  local no_scripts="${no_script%/*}" # strip /scripts -> .../1.4.0
  printf '%s\n' "${no_scripts##*/}"  # strip prefix -> 1.4.0
}

# Resolve the Claude config directory.
# Honors CLAUDE_CONFIG_DIR env var; falls back to ~/.claude.
# When CLAUDE_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_claude_config_dir() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # Validate absolute path when explicitly set
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: CLAUDE_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Validate and resolve AIMI_PLUGIN_DIR when set by compound-plugin converter.
# Returns stripped path on success, empty string when unset; exits 1 on invalid.
_validate_plugin_dir() {
  if [ -z "${AIMI_PLUGIN_DIR:-}" ]; then
    return 0
  fi
  # Must be an absolute path
  if [ "${AIMI_PLUGIN_DIR#/}" = "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR must be an absolute path, got: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Directory must exist
  if [ ! -d "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR directory does not exist: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${AIMI_PLUGIN_DIR%/}"
}

# Detect if running inside Claude Code (CLAUDECODE=1 is set by Claude Code in every session)
_is_claude_code_host() {
  [ "${CLAUDECODE:-}" = "1" ]
}

# Resolve the Aimi config directory (XDG-compliant, host-agnostic).
# Honors AIMI_CONFIG_DIR env var; falls back to ${XDG_CONFIG_HOME:-$HOME/.config}/aimi.
# When AIMI_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_aimi_config_dir() {
  local dir="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"
  # Validate absolute path when explicitly set
  if [ -n "${AIMI_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: AIMI_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Return the legacy global cache file path for aimi-cli.sh (read-fallback only)
_global_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-cli-path"
}

# Return the legacy global cache file path for worktree-manager.sh (read-fallback only)
_global_worktree_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-worktree-path"
}

# Return the global cache file path for aimi-cli.sh (new XDG location)
_global_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/cli-path"
}

# Return the global cache file path for worktree-manager.sh (new XDG location)
_global_worktree_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/worktree-path"
}

# Return the path to the models config file (XDG location)
_aimi_models_config_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models.json"
}

# Return the path to the models first-run prompt marker file for the active host.
# The marker is per-host: `models-prompt-seen-claudeCode` or `models-prompt-seen-opencode`.
# This lets a user dismiss the prompt independently on each host — picking
# "Keep the default (inherit)" on Claude Code does not silence the prompt on OpenCode.
# The legacy global `models-prompt-seen` file (no host suffix) is no longer read.
_aimi_models_prompt_marker_path() {
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-prompt-seen-$host"
}

# Return the path to THIS repository's remembered forge account store, as a
# fifth sibling of the four config-path helpers above. Prints exactly one
# absolute path on stdout; returns 1 printing nothing when the current
# directory has no resolvable git identity.
#
# WHY --git-common-dir AND NOT --show-toplevel: `--show-toplevel` answers with
# the WORKTREE path, so every `.worktrees/<branch>` checkout of one repository
# hashes to a different key and gets asked for its account all over again. This
# repository creates worktrees constantly via /aimi:execute, so that is a daily
# regression, not a corner case. `--git-common-dir` answers with the ONE shared
# `.git` directory from both the main checkout and every worktree, which is
# what makes "asks once, never again" true. This is a deliberate, recorded
# deviation from the phase-2 roadmap's success criterion 4, whose literal
# wording says "keyed by a hash of the repository toplevel" -- the roadmap was
# deliberately not amended; see US-001's notes. Everything else criterion 4
# asks for is preserved: hash-keyed, stored outside the repository, never
# committed, per-user.
#
# WHY THE VALUE MUST BE ABSOLUTE BEFORE IT IS HASHED -- load-bearing, not
# defensive: bare `git rev-parse --git-common-dir` returns a RELATIVE path.
# Verified in this repository at git 2.34.1: `.git` from the toplevel and
# `../../../.git` from plugins/aimi-engineering/scripts. Hashing that raw would
# hand EVERY repository on the machine the single shared key hash('.git')
# whenever the CLI runs from a toplevel -- the "scope too coarse" defect
# CHANGELOG 1.93.2 already had to remediate once, when a global
# models-prompt-seen marker had to become per-host -- and would also make one
# repository's key vary by current directory, re-asking from a subdirectory.
# So `--path-format=absolute` (git >= 2.31) is tried first, and the bare form
# is only a fallback that is joined against $PWD and normalized through
# resolve_path. One machine runs one git, so a single invocation never mixes
# the two routes; only the fallback normalizes symlinks, which is why the
# absolute route is the one that must stay primary.
#
# DOCUMENT SHAPE THIS PATH POINTS AT -- READ, MERGE, WRITE; NEVER `jq -n`:
# the file holds a JSON OBJECT KEYED BY FORGE HOST, e.g.
#   {"github.com": {...}, "gitlab.com": {...}}
# It is multi-entry by nature: one repository can carry remotes on more than
# one host, and phases 3 and 4 add glab/tea hosts alongside github.com. Any
# writer MUST read the existing document and merge its own host key into it,
# and MUST NOT rebuild the document with `jq -n`. That exact mistake shipped
# here before: CHANGELOG:487 (1.97.2), where `detect-models` in default mode
# rebuilt models.json with `jq -n` and silently dropped the OTHER host's
# sub-table on every single invocation (regression test
# test_detect_models_default_mode_preserves_other_host). The per-repository
# split into separate files makes sibling repositories structurally unable to
# clobber each other; the per-host merge obligation is what keeps a single
# repository's own hosts from doing it.
#
# MEMOIZES NOTHING, DELIBERATELY: like its four siblings this is a pure stdout
# printer, so every call site reaches it through `$(...)` -- and a memo
# populated inside a command-substitution subshell dies with that subshell, as
# _detect_forge_type's header spells out. Per-invocation memoization of the
# resolved ACCOUNT lives one level up instead, in the
# _forge_account_host_cached / _forge_account_override_slots pair, which uses
# exactly that name-reference discipline: the memo is warmed by a plain
# statement in the write function's own shell, and the `$(...)` lookups that
# follow inherit it.
_forge_account_store_path() {
  local common_dir=""

  # Primary: the absolute answer, straight from git.
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=""

  # Fallback for git < 2.31 (no --path-format): take the bare answer, join a
  # relative one against the current directory, and normalize.
  if [ -z "$common_dir" ] || [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir=""
    if [ -n "$common_dir" ]; then
      case "$common_dir" in
        /*) ;;
        *) common_dir="$(pwd)/$common_dir" ;;
      esac
      common_dir=$(resolve_path "$common_dir" 2>/dev/null) || common_dir=""
    fi
  fi

  # Degradation: no git repository, or git could not answer. Return non-zero
  # with empty stdout -- callers read that as "no remembered answer, proceed on
  # the active account", matching _forge_bin_check's optional-mode posture.
  # NEVER fall through to hashing the empty string the way _resolve_default_branch
  # tolerates an empty toplevel: hash('') would become ONE global "no-repo"
  # store every non-repo caller writes into, which is precisely the coarse-scope
  # defect the absolute-path guarantee above exists to prevent. Silent by
  # design -- being outside a repository is an expected condition, not an error.
  if [ -z "$common_dir" ] || [ "${common_dir#/}" = "$common_dir" ]; then
    return 1
  fi

  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/forge-account-$(_default_branch_cache_key "$common_dir").json"
}

# Read the models config JSON, returning empty string when the file is absent.
# Does not validate contents — callers must handle malformed JSON.
read_aimi_models_config() {
  local config_file
  config_file=$(_aimi_models_config_path)
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  cat "$config_file" 2>/dev/null
}

# Atomically write JSON content to the models config file (chmod 0600, mktemp + mv).
# Usage: write_aimi_models_config <json_content>
# Mirrors write_global_cli_cache — interrupted runs never corrupt a pre-existing file.
# chmod is applied BEFORE writing content (create-then-restrict-then-write pattern).
# Temp file is removed on mv failure so no stray files remain.
write_aimi_models_config() {
  local json_content="$1"
  local config_file
  config_file=$(_aimi_models_config_path)
  local config_dir
  config_dir=$(dirname "$config_file")
  if ! mkdir -p "$config_dir" 2>/dev/null; then
    echo "Error: write_aimi_models_config: cannot create directory: $config_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${config_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf '%s\n' "$json_content" > "$tmp_file"
  if ! mv "$tmp_file" "$config_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: write_aimi_models_config: mv failed for $config_file" >&2
    return 1
  fi
}

# Atomically write the CLI path to the global cache file
# Usage: write_global_cli_cache "/path/to/aimi-cli.sh"
# Never persists an ephemeral git-worktree copy: a path under a `.worktrees/`
# segment is invoked from a throwaway checkout (e.g. test-aimi-cli.sh running
# inside a worktree, or an /aimi:execute wave). Caching it globally would point
# every later session at a file that vanishes on worktree cleanup (exit 127).
write_global_cli_cache() {
  local path="$1"
  case "$path" in
    */.worktrees/*)
      # Refuse to cache a worktree-local copy globally; treat as no-op success.
      return 0
      ;;
  esac
  local cache_file
  cache_file=$(_global_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_cli_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_cached_cli_path: run a path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
_validate_cached_cli_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/scripts/aimi-cli.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Read and validate the cached CLI path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_cli_cache() {
  local cache_file
  cache_file=$(_global_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_cli_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_cli_path "$cached_path"
}

# Atomically write the worktree manager path to the global cache file
# Usage: write_global_worktree_cache "/path/to/worktree-manager.sh"
write_global_worktree_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_worktree_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_cached_worktree_path: run a worktree path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
_validate_cached_worktree_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/skills/git-worktree/scripts/worktree-manager.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Read and validate the cached worktree manager path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_worktree_cache() {
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_worktree_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_worktree_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_worktree_path "$cached_path"
}

# Validate story ID format (US-NNN or US-NNNa)
validate_story_id() {
  local story_id="$1"
  if ! [[ "$story_id" =~ ^US-[0-9]{3}[a-z]?$ ]]; then
    echo "Error: Invalid story ID format: $story_id (expected US-NNN)" >&2
    exit 1
  fi
}

# Validate story ID exists in the tasks file
validate_story_exists() {
  local story_id="$1"
  local tasks_file="$2"
  if ! jq -e --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file" > /dev/null 2>&1; then
    echo "Error: Story $story_id not found in $tasks_file" >&2
    exit 1
  fi
}

# Discover tasks files across both the flat layout (.aimi/tasks/*-tasks.json)
# and the nested phase-folder layout (.aimi/tasks/<feature>/phase-N[.M]-<slug>/
# <feature>-phase-N-tasks.json), sorted by modification time with the most
# recent file first. mindepth 1/maxdepth 3 covers flat files (depth 1) and
# nested phase files (feature dir depth 1, phase dir depth 2, tasks file
# depth 3) in one pass. Shared by cmd_find_tasks, cmd_find_tasks_all, and
# get_tasks_file's stale-state fallback so all three see the same combined
# view instead of a flat-only glob. Prints nothing (not an error) when
# TASKS_DIR is missing or empty.
# NUL-delimited find -> xargs -0 keeps paths containing spaces intact. A
# newline-delimited `xargs ls -t` word-splits them, which silently emptied
# discovery for any project whose path contains a space (regression vs the
# pre-phase-layer quoted glob).
_find_tasks_files_all() {
  [ -d "$TASKS_DIR" ] || return 0
  find "$TASKS_DIR" -mindepth 1 -maxdepth 3 -type f -name '*-tasks.json' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null || true
}

# Get the tasks file (from state or discover)
get_tasks_file() {
  local tasks_file
  tasks_file=$(read_state "current-tasks")

  if [ -n "$tasks_file" ] && [ ! -f "$tasks_file" ]; then
    local stale_path="$tasks_file"
    tasks_file=$(_find_tasks_files_all | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
    echo "Warning: state file pointed to $stale_path which no longer exists. Using $tasks_file instead." >&2
    write_state "current-tasks" "$tasks_file"
  elif [ -z "$tasks_file" ]; then
    tasks_file=$(_find_tasks_files_all | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    validate_path_in_project "$tasks_file"
  fi

  echo "$tasks_file"
}

# ============================================================================
# Commands
# ============================================================================

# Find the most recent tasks file (flat or nested phase layout)
cmd_find_tasks() {
  local tasks_file
  tasks_file=$(_find_tasks_files_all | head -1)

  if [ -z "$tasks_file" ]; then
    echo "No tasks file found in $TASKS_DIR/" >&2
    exit 1
  fi

  resolve_path "$tasks_file"
}

# Find all tasks files sorted by modification time (most recent first),
# across both the flat and nested phase layouts.
cmd_find_tasks_all() {
  local files
  files=$(_find_tasks_files_all)

  if [ -z "$files" ]; then
    echo "No tasks files found in $TASKS_DIR/" >&2
    exit 1
  fi

  # Output each file as an absolute path, newline-separated
  while IFS= read -r f; do
    resolve_path "$f"
  done <<< "$files"
}

# Initialize execution session
# Usage: aimi-cli.sh init-session [--file <path>]
cmd_init_session() {
  local tasks_file branch pending
  local file_flag=""

  # Parse optional --file flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)
        shift
        file_flag="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
      *)
        echo "Error: Unexpected argument: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$file_flag" ]; then
    # Validate the --file path exists
    if [ ! -f "$file_flag" ]; then
      echo "Error: File not found: $file_flag" >&2
      exit 1
    fi
    # Validate it matches *-tasks.json pattern
    local basename
    basename=$(basename "$file_flag")
    if ! [[ "$basename" == *-tasks.json ]]; then
      echo "Error: File does not match *-tasks.json pattern: $file_flag" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$file_flag")
  else
    tasks_file=$(cmd_find_tasks)
  fi
  write_state "current-tasks" "$tasks_file"

  # Self-resolve: persist this CLI's absolute path for future sessions
  local self_path
  self_path=$(resolve_path "$0")
  write_state "cli-path" "$self_path"
  write_global_cli_cache "$self_path"

  branch=$(jq -r '.metadata.branchName' "$tasks_file")

  # Validate branch name (security)
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  write_state "current-branch" "$branch"

  pending=$(jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file")

  local version
  version=$(jq -r '.schemaVersion' "$tasks_file")

  jq -n --arg tasks "$tasks_file" --arg branch "$branch" --argjson pending "$pending" --arg version "$version" \
    '{tasks: $tasks, branch: $branch, pending: $pending, schemaVersion: $version}'
}

# Get comprehensive status summary
# Flags: --counts-only (return aggregate counts without userStories array)
cmd_status() {
  local counts_only=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --counts-only) counts_only=true; shift ;;
      *) break ;;
    esac
  done

  local tasks_file
  tasks_file=$(get_tasks_file)

  if [ "$counts_only" = true ]; then
    jq '{
      schemaVersion: .schemaVersion,
      title: .metadata.title,
      branch: .metadata.branchName,
      maxConcurrency: ((.metadata.maxConcurrency // 20) | if . <= 0 then 20 else . end),
      pending: [.userStories[] | select(.status == "pending")] | length,
      in_progress: [.userStories[] | select(.status == "in_progress")] | length,
      completed: [.userStories[] | select(.status == "completed")] | length,
      failed: [.userStories[] | select(.status == "failed")] | length,
      skipped: [.userStories[] | select(.status == "skipped")] | length,
      total: .userStories | length
    }' "$tasks_file"
  else
    jq '{
      schemaVersion: .schemaVersion,
      title: .metadata.title,
      branch: .metadata.branchName,
      maxConcurrency: ((.metadata.maxConcurrency // 20) | if . <= 0 then 20 else . end),
      pending: [.userStories[] | select(.status == "pending")] | length,
      in_progress: [.userStories[] | select(.status == "in_progress")] | length,
      completed: [.userStories[] | select(.status == "completed")] | length,
      failed: [.userStories[] | select(.status == "failed")] | length,
      skipped: [.userStories[] | select(.status == "skipped")] | length,
      total: .userStories | length,
      userStories: [.userStories[] | {id, title, status, dependsOn: (.dependsOn // []), priority, notes}]
    }' "$tasks_file"
  fi
}

# Get metadata only
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata | .maxConcurrency = ((.maxConcurrency // 20) | if . <= 0 then 20 else . end)' "$tasks_file"
}

# List stories that are ready to execute
# A story is ready when: status == "pending" AND all dependsOn stories have status "completed" or "skipped"
# Flags: --brief (return only {id, title, priority, dependsOn} per story)
cmd_list_ready() {
  local brief=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) brief=true; shift ;;
      *) break ;;
    esac
  done

  local tasks_file
  tasks_file=$(get_tasks_file)

  local result
  result=$(jq '
    . as $root |
    [
      .userStories[] |
      select(.status == "pending") |
      . as $story |
      # Gate filtering: exclude stories with pending decision gates
      select(
        (.gate.type != "decision") or (.gate.status != "pending")
      ) |
      # Gate filtering: exclude stories where any dependency has a pending action gate
      select(
        (($story.dependsOn // []) | length == 0) or
        (($story.dependsOn // []) | all(. as $dep_id |
          $root.userStories[] | select(.id == $dep_id) |
          ((.gate.type != "action") or (.gate.status != "pending"))
        ))
      ) |
      . as $story |
      (
        ($story.dependsOn // []) | length == 0
      ) or (
        ($story.dependsOn // []) |
        all(. as $dep_id |
          ($root.userStories[] | select(.id == $dep_id) | .status) as $dep_status |
          ($dep_status == "completed" or $dep_status == "skipped")
        )
      )
    | if . then $story else empty end
    ]
  ' "$tasks_file")

  if [ "$brief" = true ]; then
    echo "$result" | jq '[.[] | {id, title, priority, dependsOn, project, gate}]'
  else
    echo "$result"
  fi
}

# Get next pending story
cmd_next_story() {
  local story story_id

  # Use list-ready logic, then pick first by priority
  story=$(cmd_list_ready | jq 'sort_by(.priority) | .[0]')

  if [ "$story" = "null" ] || [ -z "$story" ]; then
    clear_state_file "current-story"
    echo "null"
    return
  fi

  story_id=$(echo "$story" | jq -r '.id')
  write_state "current-story" "$story_id"

  echo "$story"
}

# Get currently active story from state
cmd_current_story() {
  local story_id tasks_file
  story_id=$(read_state "current-story")

  if [ -z "$story_id" ]; then
    echo "null"
    return
  fi

  tasks_file=$(get_tasks_file)
  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Get full story object by ID (read-only)
cmd_get_story() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Resolve the skills base directory for the current host.
# Returns the absolute path to the skills/ directory, or empty string when unresolvable.
# Claude Code (CLAUDECODE=1): glob ~/.claude/plugins/cache/*/aimi-engineering/*/skills, take first.
# OpenCode (AIMI_PLUGIN_DIR set, CLAUDECODE unset): $AIMI_PLUGIN_DIR/skills.
# Otherwise: empty string — caller emits skills: [] silently.
_resolve_skills_base_dir() {
  if _is_claude_code_host; then
    local config_dir
    config_dir=$(_claude_config_dir)
    local skills_dir
    skills_dir=$(bash -c "ls -d \"$config_dir\"/plugins/cache/*/aimi-engineering/*/skills 2>/dev/null | head -1")
    printf '%s\n' "${skills_dir:-}"
    return 0
  fi
  if [ -n "${AIMI_PLUGIN_DIR:-}" ]; then
    local plugin_dir
    plugin_dir=$(_validate_plugin_dir)
    if [ -n "$plugin_dir" ]; then
      printf '%s\n' "$plugin_dir/skills"
      return 0
    fi
  fi
  printf ''
}

# Get story context (story slice + metadata + skills + designContext) by ID — for subagent self-brief
cmd_get_story_context() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story-context <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # ---- Resolve skills ----
  local skills_base_dir
  skills_base_dir=$(_resolve_skills_base_dir)

  # Read skill names declared by this story
  local skill_names_json
  skill_names_json=$(jq -r --arg id "$story_id" \
    '(.userStories[] | select(.id == $id) | .skills // []) | @json' "$tasks_file")

  # Build skills array: name, path, content
  # We accumulate in a bash array of jq --arg entries, then assemble with jq.
  local skill_names_arr
  mapfile -t skill_names_arr < <(echo "$skill_names_json" | jq -r '.[]' 2>/dev/null)

  # Collect valid skill entries and track aggregate char count
  local skill_names_collected=()
  local skill_contents_collected=()
  local skill_aggregate_chars=0

  local skill_name
  for skill_name in "${skill_names_arr[@]+"${skill_names_arr[@]}"}"; do
    local skill_rel_path="skills/${skill_name}/SKILL.md"
    if [ -z "$skills_base_dir" ]; then
      # No resolution — skip silently (aggregate will be empty)
      continue
    fi
    local skill_abs_path="${skills_base_dir}/${skill_name}/SKILL.md"
    if [ ! -f "$skill_abs_path" ]; then
      # OpenCode installs skills under an `aimi-` prefix (install.sh install_skills:
      # dst="$skill_dir/aimi-$skillname"), while stories declare the bare skill
      # name. Claude Code's cache dir is unprefixed, so the bare path already
      # resolved above there. Fall back to the prefixed dir so OpenCode hydration
      # is not silently skipped. Host-agnostic: on Claude Code this fallback path
      # simply does not exist and the warning below still fires for a genuinely
      # missing skill.
      local skill_prefixed_path="${skills_base_dir}/aimi-${skill_name}/SKILL.md"
      if [ -f "$skill_prefixed_path" ]; then
        skill_abs_path="$skill_prefixed_path"
      else
        echo "skill ${skill_name} not found at ${skill_rel_path} — skipped" >&2
        continue
      fi
    fi
    # Read content and apply tag-breakout escapes before jq ingestion
    local skill_content
    skill_content=$(sed \
      -e 's|</required_skills|\&lt;/required_skills|g' \
      -e 's|<required_skills|\&lt;required_skills|g' \
      "$skill_abs_path")
    skill_names_collected+=("$skill_name")
    skill_contents_collected+=("$skill_content")
    (( skill_aggregate_chars += ${#skill_content} ))
  done

  # Apply 100KB aggregate cap: pop in reverse-of-insertion order until aggregate <= 102400
  local cap=102400
  while [ "${skill_aggregate_chars}" -gt "${cap}" ] && [ "${#skill_names_collected[@]}" -gt 0 ]; do
    local last_idx=$(( ${#skill_names_collected[@]} - 1 ))
    local dropped_name="${skill_names_collected[$last_idx]}"
    local dropped_len="${#skill_contents_collected[$last_idx]}"
    echo "skill ${dropped_name} dropped — aggregate skills context exceeded 100KB" >&2
    unset 'skill_names_collected[$last_idx]'
    unset 'skill_contents_collected[$last_idx]'
    skill_names_collected=("${skill_names_collected[@]+"${skill_names_collected[@]}"}")
    skill_contents_collected=("${skill_contents_collected[@]+"${skill_contents_collected[@]}"}")
    (( skill_aggregate_chars -= dropped_len ))
  done

  # Build skills JSON array using jq with null input
  local skills_json='[]'
  local i
  for (( i=0; i<${#skill_names_collected[@]}; i++ )); do
    local sname="${skill_names_collected[$i]}"
    local scontent="${skill_contents_collected[$i]}"
    local spath="skills/${sname}/SKILL.md"
    skills_json=$(jq -n \
      --argjson existing "$skills_json" \
      --arg name "$sname" \
      --arg path "$spath" \
      --arg content "$scontent" \
      '$existing + [{name: $name, path: $path, content: $content}]')
  done

  # ---- Resolve designContext ----
  local brainstorm_path_rel decisions_text=""
  brainstorm_path_rel=$(jq -r --arg id "$story_id" '.metadata.brainstormPath // empty' "$tasks_file")

  if [ -n "$brainstorm_path_rel" ]; then
    # Resolve relative to PROJECT_ROOT (absolute if already absolute)
    local brainstorm_abs
    if [ "${brainstorm_path_rel#/}" = "$brainstorm_path_rel" ]; then
      brainstorm_abs="${PROJECT_ROOT}/${brainstorm_path_rel}"
    else
      brainstorm_abs="$brainstorm_path_rel"
    fi
    if [ -f "$brainstorm_abs" ]; then
      # Extract the ## Design Decisions section: text from that heading up to (but not
      # including) the next ## heading (or end of file).
      decisions_text=$(awk '
        /^## Design Decisions/ { in_section=1; next }
        in_section && /^## / { exit }
        in_section { print }
      ' "$brainstorm_abs" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
        awk 'NF || (prev_nf) {print; prev_nf=NF}' | \
        sed '/^$/d' | head -c 65536)
    fi
  fi

  # bundleGuidance
  local bundle_guidance=""
  local design_bundle_json
  design_bundle_json=$(jq -r '.metadata.designBundle // empty' "$tasks_file" 2>/dev/null)
  if [ -n "$design_bundle_json" ]; then
    local bundle_root design_spec business_spec
    bundle_root=$(jq -r '.metadata.designBundle.root // "(none)"' "$tasks_file")
    design_spec=$(jq -r '.metadata.designBundle.designSpec // "(none)"' "$tasks_file")
    business_spec=$(jq -r '.metadata.designBundle.businessSpec // "(none)"' "$tasks_file")
    bundle_guidance="Apply design bundle fidelity rules. Read the spec files cited below using the Read tool before authoring implementation code.

Bundle root: ${bundle_root}
DesignSpec: ${design_spec}
BusinessSpec: ${business_spec}"
  fi

  # ---- Emit final JSON ----
  jq -n \
    --arg id "$story_id" \
    --argjson skills "$skills_json" \
    --arg decisions "$decisions_text" \
    --arg bundleGuidance "$bundle_guidance" \
    --slurpfile tf "$tasks_file" \
    '{
      story: ($tf[0].userStories[] | select(.id == $id)),
      metadata: $tf[0].metadata,
      skills: $skills,
      designContext: {
        decisions: $decisions,
        bundleGuidance: $bundleGuidance
      }
    }'
}

# Mark a story as in-progress
cmd_mark_in_progress() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-in-progress <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "in_progress"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  write_state "current-story" "$story_id"

  printf '{"id":"%s","status":"in_progress"}\n' "$story_id"
}

# Mark a story as complete
cmd_mark_complete() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "completed"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "success"

  printf '{"id":"%s","status":"completed"}\n' "$story_id"
}

# Mark a story as failed with notes
cmd_mark_failed() {
  local story_id="$1"
  local notes="${2:-}"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-failed <story-id> [notes]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" --arg notes "$notes" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "failed", notes: $notes}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "failed"

  printf '{"id":"%s","status":"failed","notes":"%s"}\n' "$story_id" "$notes"
}

# Mark a story as skipped
cmd_mark_skipped() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "skipped"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  printf '{"id":"%s","status":"skipped"}\n' "$story_id"
}

# Persist a --container/--inline override onto metadata.execution.
# execute.md and next.md call this after resolving a session-level override so
# a later re-invocation without the flag continues in the same mode instead of
# silently falling back to the file's original value. Refuses (non-zero exit)
# on a phase-scoped tasks file (metadata.phase present) — a claimed phase
# always runs inside its own phase container, so writing metadata.execution
# there would be the exact dead-data bug this subcommand exists to fix.
cmd_set_execution_mode() {
  local mode="$1"
  local tasks_file

  if [ -z "$mode" ]; then
    echo "Usage: aimi-cli.sh set-execution-mode <container|inline>" >&2
    exit 1
  fi

  if [ "$mode" != "container" ] && [ "$mode" != "inline" ]; then
    echo "Error: Invalid execution mode: $mode (expected container or inline)" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  local has_phase
  has_phase=$(jq -r 'if (.metadata.phase // null) != null then "true" else "false" end' "$tasks_file")
  if [ "$has_phase" = "true" ]; then
    echo "Error: Cannot set metadata.execution on a phase-scoped tasks file (metadata.phase is present): $tasks_file" >&2
    exit 1
  fi

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg mode "$mode" \
      '.metadata.execution = $mode' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  printf '{"execution":"%s"}\n' "$mode"
}

# Count pending stories
cmd_count_pending() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file"
}

# Validate dependencies in a tasks file
# Checks for: circular dependencies, missing IDs, self-references
cmd_validate_deps() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local errors
  errors=$(jq '
    . as $root |
    ($root.userStories | map(.id)) as $all_ids |

    # Check self-references
    (
      [
        $root.userStories[] |
        . as $story |
        select(($story.dependsOn // []) | any(. == $story.id)) |
        "Self-reference: \($story.id) depends on itself"
      ]
    ) as $self_refs |

    # Check missing references
    (
      [
        $root.userStories[] |
        . as $story |
        ($story.dependsOn // [])[] |
        . as $dep |
        select(($all_ids | index($dep)) == null) |
        "Missing ID: \($story.id) depends on \($dep) which does not exist"
      ]
    ) as $missing_refs |

    # Check circular dependencies using iterative reachability
    # For each story, walk its dependency graph and check if it reaches itself
    (
      [
        $root.userStories[] |
        . as $start |
        $start.id as $start_id |
        # Build reachability: iterate N times where N = number of stories
        (
          [$start_id] as $initial |
          reduce range($root.userStories | length) as $_ (
            ($start.dependsOn // []);
            . as $current |
            ($current + [
              $root.userStories[] |
              select((.id) as $sid | $current | any(. == $sid)) |
              (.dependsOn // [])[]
            ]) | unique
          )
        ) |
        if any(. == $start_id) then
          "Circular dependency: \($start_id) is part of a dependency cycle"
        else
          empty
        end
      ]
    ) as $cycles |

    ($self_refs + $missing_refs + $cycles) |
    if length == 0 then
      {valid: true, errors: []}
    else
      {valid: false, errors: .}
    end
  ' "$tasks_file")

  echo "$errors"

  # Return non-zero exit code if invalid
  local is_valid
  is_valid=$(echo "$errors" | jq -r '.valid')
  if [ "$is_valid" != "true" ]; then
    return 1
  fi
}

# Validate story content (field lengths, suspicious patterns)
cmd_validate_stories() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local result
  result=$(jq '
    .userStories as $stories |
    [
      $stories[] |
      . as $s |
      (
        (if ($s.title | length) > 200 then ["\($s.id): title exceeds 200 chars"] else [] end) +
        (if ($s.description | length) > 500 then ["\($s.id): description exceeds 500 chars"] else [] end) +
        ([$s.acceptanceCriteria[] | select(length > 5000)] | if length > 0 then ["\($s.id): acceptance criterion exceeds 5000 chars"] else [] end) +
        (if ($s.title | test("ignore previous|(^|\\s)[^a-zA-Z0-9]*system\\s*:|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b|INSTRUCTIONS\\s*:|```|\\$\\("; "i")) then ["\($s.id): title contains suspicious content"] else [] end) +
        (if ($s.description | test("ignore previous|(^|\\s)[^a-zA-Z0-9]*system\\s*:|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b|INSTRUCTIONS\\s*:|```|\\$\\("; "i")) then ["\($s.id): description contains suspicious content"] else [] end) +
        (if ($s.project != null) then
          (if ($s.project | test("^/")) then ["\($s.id): project must not be an absolute path"]
           elif ($s.project | test("\\.\\.")) then ["\($s.id): project must not contain path traversal (..)"]
           elif ($s.project | test("[\\$`;|&]")) then ["\($s.id): project contains shell metacharacters"]
           elif ($s.project | test("^[a-zA-Z0-9_.][a-zA-Z0-9_./@-]*$") | not) then ["\($s.id): project contains invalid characters"]
           else [] end)
         else [] end) +
        (if ($s.skills != null) then
          (if ($s.skills | type) != "array" then ["\($s.id): skills must be an array"]
           else
             (if ($s.skills | length) > 10 then ["\($s.id): skills array exceeds 10 entries"] else [] end) +
             [$s.skills[] | select(test("^[a-zA-Z0-9][a-zA-Z0-9_-]*$") | not) | "\($s.id): skills[" + (. | tostring) + "] contains invalid characters"] +
             [$s.skills[] | select(test("\\.\\.") or test("/") or test("[\\$`;|&]")) | "\($s.id): skills[" + (. | tostring) + "] must not contain path components"] +
             (if ($s.skills | unique | length) != ($s.skills | length) then
               [$s.skills | group_by(.) | .[] | select(length > 1) | .[0] | "\($s.id): skills contains duplicate entry \(.)"]
             else [] end)
           end)
         else [] end) +
        (if ($s.tasks != null) then
          (if ($s.tasks | type) != "array" then ["\($s.id): tasks must be an array"]
           elif ($s.tasks | length) == 0 then ["\($s.id): tasks must be omitted when empty"]
           else
             (if ($s.tasks | length) > 50 then ["\($s.id): tasks array exceeds 50 entries"] else [] end) +
             [$s.tasks[] | select(type != "string") | "\($s.id): tasks[] element must be a string"] +
             [$s.tasks[] | select(type == "string" and length > 5000) | "\($s.id): tasks[] entry exceeds 5000 chars"] +
             [$s.tasks[] | select(type == "string" and test("ignore previous|(^|\\s)[^a-zA-Z0-9]*system\\s*:|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b|INSTRUCTIONS\\s*:|```|\\$\\("; "i")) | "\($s.id): tasks[] entry contains suspicious content"]
           end)
         else [] end) +
        (if has("gates") then ["\($s.id): gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)"] else [] end) +
        (if ($s.gate != null) then
          (["type","status","prompt"] | map(. as $k | if ($s.gate | has($k) | not) then ["\($s.id): gate: missing required field \($k)"] else [] end) | add // [])
         else [] end) +
        (if ($s.verification != null and ($s.verification | type) == "string") then
          ["\($s.id): verification must be an object {strategy, status, url, expect}; found bare string — run normalize-verification to fix"]
         else [] end) +
        (if (has("status") | not) then
          ["\($s.id): missing required field: status — run normalize-status to fix"]
         else [] end)
      ) | .[]
    ] |
    if length == 0 then {valid: true, errors: []}
    else {valid: false, errors: .}
    end
  ' "$tasks_file")
  local jq_exit=$?
  echo "$result"
  [ $jq_exit -ne 0 ] && return $jq_exit
  # Return exit 1 when validation found errors
  if echo "$result" | jq -e '.valid == false' > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Normalize verification fields: rewrite any bare-string verification into object form
cmd_normalize_verification() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-verification <tasks-file-path>" >&2
    exit 1
  fi

  if [ ! -f "$tasks_file" ]; then
    echo "Error: tasks file not found: $tasks_file" >&2
    exit 1
  fi

  if [ ! -r "$tasks_file" ]; then
    echo "Error: tasks file not readable: $tasks_file" >&2
    exit 1
  fi

  # Validate input is valid JSON
  if ! jq empty "$tasks_file" 2>/dev/null; then
    echo "Error: invalid JSON in tasks file: $tasks_file" >&2
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq '
      .userStories |= map(
        if (.verification != null and (.verification | type) == "string") then
          .verification = {strategy: .verification, status: "pending", url: null, expect: null}
        else
          .
        end
      )
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  [ $exit_code -ne 0 ] && exit $exit_code

  # Report how many stories were normalized
  local normalized_count
  normalized_count=$(jq '[.userStories[] | select(.verification != null and (.verification | type) == "object")] | length' "$tasks_file")
  jq -n --argjson count "$normalized_count" '{normalized: $count}'
}

# Normalize status fields: default any story missing the status field to "pending"
cmd_normalize_status() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-status <tasks-file-path>" >&2
    exit 1
  fi

  if [ ! -f "$tasks_file" ]; then
    echo "Error: tasks file not found: $tasks_file" >&2
    exit 1
  fi

  if [ ! -r "$tasks_file" ]; then
    echo "Error: tasks file not readable: $tasks_file" >&2
    exit 1
  fi

  # Validate input is valid JSON
  if ! jq empty "$tasks_file" 2>/dev/null; then
    echo "Error: invalid JSON in tasks file: $tasks_file" >&2
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq '
      .userStories |= map(.status //= "pending")
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  [ $exit_code -ne 0 ] && exit $exit_code

  # Report how many stories were healed (now have status field)
  local healed_count
  healed_count=$(jq '[.userStories[] | select(has("status"))] | length' "$tasks_file")
  jq -n --argjson count "$healed_count" '{normalized: $count}'
}

# Validate all story IDs in the tasks file against the US-NNN format
cmd_validate_ids() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local ids errors=() count=0
  ids=$(jq -r '.userStories[].id' "$tasks_file")

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    count=$((count + 1))
    if ! [[ "$id" =~ ^US-[0-9]{3}[a-z]?$ ]]; then
      errors+=("Invalid story ID: $id (expected US-NNN)")
    fi
  done <<< "$ids"

  if [ ${#errors[@]} -eq 0 ]; then
    jq -n --argjson count "$count" '{valid: true, count: $count}'
    return 0
  else
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
    jq -n --argjson errors "$errors_json" '{valid: false, errors: $errors}'
    return 1
  fi
}

# Cascade skip: given a failed story ID, mark all transitively-dependent stories as skipped
cmd_cascade_skip() {
  local failed_id="$1"
  local tasks_file

  if [ -z "$failed_id" ]; then
    echo "Usage: aimi-cli.sh cascade-skip <story-id>" >&2
    exit 1
  fi

  validate_story_id "$failed_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$failed_id" "$tasks_file"

  # Find all stories that transitively depend on the failed story and mark them as skipped

  # First compute which IDs to skip
  local to_skip
  to_skip=$(jq --arg failed_id "$failed_id" '
    . as $root |
    (
      reduce range($root.userStories | length) as $_ (
        [$failed_id];
        . as $skip_ids |
        ($skip_ids + [
          $root.userStories[] |
          select(
            (.status != "completed") and
            (.status != "skipped") and
            ((.dependsOn // []) | any(. as $d | $skip_ids | any(. == $d)))
          ) |
          .id
        ]) | unique
      )
    ) | map(select(. != $failed_id))
  ' "$tasks_file")

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg failed_id "$failed_id" --argjson to_skip "$to_skip" '
      .userStories |= [
        .[] |
        if (.id as $sid | $to_skip | any(. == $sid)) then
          . + {status: "skipped", notes: ("Skipped: depends on failed story " + $failed_id)}
        else
          .
        end
      ]
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  # Output result
  local count
  count=$(echo "$to_skip" | jq 'length')
  jq -n --argjson skipped "$to_skip" --argjson count "$count" \
    '{skipped: $skipped, count: $count}'
}

# Reset orphaned in_progress stories to failed
cmd_reset_orphaned() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  # Find all in_progress story IDs
  local orphaned
  orphaned=$(jq '[.userStories[] | select(.status == "in_progress") | .id]' "$tasks_file")

  local count
  count=$(echo "$orphaned" | jq 'length')

  if [ "$count" -eq 0 ]; then
    jq -n '{count: 0, reset: []}'
    return
  fi

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq '(.userStories[] | select(.status == "in_progress")) |= . + {status: "failed", notes: "Reset: orphaned from previous session"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq -n --argjson reset "$orphaned" --argjson count "$count" \
    '{count: $count, reset: $reset}'
}

# Get branch name
cmd_get_branch() {
  local branch
  branch=$(read_state "current-branch")

  if [ -z "$branch" ]; then
    local tasks_file
    tasks_file=$(get_tasks_file)
    branch=$(jq -r '.metadata.branchName' "$tasks_file")
  fi

  echo "$branch"
}

# Get all state as JSON
cmd_get_state() {
  local tasks branch story last
  tasks=$(read_state "current-tasks")
  branch=$(read_state "current-branch")
  story=$(read_state "current-story")
  last=$(read_state "last-result")

  jq -n \
    --arg tasks "$tasks" \
    --arg branch "$branch" \
    --arg story "$story" \
    --arg last "$last" \
    '{
      tasks: (if $tasks == "" then null else $tasks end),
      branch: (if $branch == "" then null else $branch end),
      story: (if $story == "" then null else $story end),
      last: (if $last == "" then null else $last end)
    }'
}

# Shared `--project`/git-repository entry guard. Fourteen commands each
# carried a byte-identical copy of this block before it was extracted here:
# cd into the requested project directory when one was given (multi-repo
# layouts, where the AIMI root is not itself a git repo), then require the
# resulting working directory to be a git repository. Exits 1 with the
# unchanged wording on either failure.
#
# An empty argument means "use the invoking CWD" -- which is exactly what an
# omitted --project already resolved to, so no caller needs to special-case it.
# The `cd` intentionally escapes into the caller (a function's cd is not
# scoped), because that is what the fourteen inline copies did.
#
# Deliberately NOT named _forge_*: ten of the fourteen callers are forge verbs,
# but cmd_detect_default_branch, cmd_detect_parent_branch, cmd_setup_branch and
# cmd_resolve_base_branch share this guard by behaviour, not by domain. A forge
# prefix would misdescribe a quarter of its own callers, so the name follows
# this file's other domain-neutral private helpers (_local_has_branch,
# _is_merged_into_default, _is_pid_alive).
#
# Usage: _require_git_repo "$project_dir"
_require_git_repo() {
  local project_dir="$1"
  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi
}

# Derive a filesystem-safe cache-key suffix for a repository toplevel path,
# so _resolve_default_branch's cache is scoped per repository instead of a
# single shared file under AIMI_ROOT/.aimi/ (which silently leaked one
# repo's resolved branch into every sibling --project call). Mirrors the
# sha256sum/shasum branch shape of _hash_file (aimi-cli.sh:2035-2042) but
# adds an explicit `command -v shasum` probe that helper lacks, and falls
# back to a portable non-sha256 slugification when neither hashing tool is
# available -- the slugification never introduces a `/`, so the returned
# suffix is always safe to use as a flat filename directly inside .aimi/.
# SECOND CALLER since phase 2: _forge_account_store_path hashes the absolute
# git common dir with this same helper. Its behavior is therefore frozen --
# the digest emitted for a given input must stay byte-identical, because
# `.aimi/default-branch-<hash>` files already exist on disk.
# Usage: _default_branch_cache_key <repo-toplevel-path>
# Prints: a filesystem-safe string containing no `/`
_default_branch_cache_key() {
  local toplevel="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    printf '%s' "$toplevel" | sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    printf '%s' "$toplevel" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$toplevel" | tr -c 'A-Za-z0-9' '-'
  fi
}

# Shared default-branch resolution logic: cache read, primary git remote
# show origin parse, offline symbolic-ref fallback, cache write. Assumes the
# caller has already cd'd into the target repo and verified it is a git
# repository (both cmd_detect_default_branch and cmd_detect_parent_branch
# do this themselves before calling here). The cache is keyed per repository
# toplevel (default-branch-<hash>) rather than a single shared
# "default-branch" file, so a sibling repo's --project call cannot inherit
# another repo's cached branch. Returns the branch name on stdout; exits 1
# on total failure.
_resolve_default_branch() {
  local repo_toplevel cache_key
  repo_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || repo_toplevel=""
  cache_key="default-branch-$(_default_branch_cache_key "$repo_toplevel")"

  # Return cached value if available
  local cached
  cached=$(read_state "$cache_key")
  if [ -n "$cached" ]; then
    echo "$cached"
    return 0
  fi

  local branch=""

  # Primary: parse HEAD branch from remote
  branch=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p') || branch=""

  # Fallback: symbolic-ref (works offline)
  if [ -z "$branch" ]; then
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || branch=""
  fi

  if [ -z "$branch" ]; then
    echo "Error: Could not detect default branch" >&2
    exit 1
  fi

  # Cache for session reuse
  write_state "$cache_key" "$branch"
  echo "$branch"
}

# Detect the repository's default branch
# Primary: git remote show origin (requires network)
# Fallback: git symbolic-ref refs/remotes/origin/HEAD (offline)
# Caches result in .aimi/default-branch for session reuse
cmd_detect_default_branch() {
  local project_dir=""

  # Parse --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _resolve_default_branch
}

# ============================================================================
# Forge Detection (detect-forge)
# ============================================================================
# FOUNDATIONAL CONTRACT for every forge-* verb in this phase: the output
# shape {forge, host, remote, remoteUrl, source} is consumed verbatim
# downstream and must not be re-derived. See cmd_help's detect-forge entry
# and this story's acceptance criteria for the full contract.

# Parse a git remote URL's hostname: lowercased, no port, no userinfo, no
# path. Handles three shapes: an explicit ssh://[user[:pass]@]host[:port]/path
# or https://[user[:pass]@]host[:port]/path (strip scheme, then strip
# userinfo up to the LAST "@" within the authority only -- never inside the
# path -- then split a trailing :<digits> port off the authority), and git's
# scp-like [user@]host:path form (no "://" present -- the substring up to the
# FIRST ":" is the host, everything after it is PATH, never a port; this is
# the exact ambiguity an alternate-port ssh://...:2222/... URL must not
# collide with). Prints empty on an unparseable string.
_detect_forge_parse_host() {
  local url host authority rest
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  host=""

  if [[ "$url" == *"://"* ]]; then
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$authority" == *"@"* ]]; then
      authority="${authority##*@}"
    fi
    if [[ "$authority" =~ ^(.+):([0-9]+)$ ]]; then
      host="${BASH_REMATCH[1]}"
    else
      host="$authority"
    fi
  elif [[ "$url" == *":"* ]]; then
    rest="$url"
    if [[ "$rest" == *"@"* ]]; then
      rest="${rest##*@}"
    fi
    host="${rest%%:*}"
  fi

  printf '%s' "$host"
}

# Exact-or-subdomain classification of a lowercase hostname against the fixed
# known-forge host list, first match wins: github.com -> github; gitlab.com
# -> gitlab; gitea.com, codeberg.org -> gitea. Gitea's own SaaS host and
# codeberg.org (the largest public Forgejo instance) are both recognized
# under the single "gitea" adapter, since Forgejo is a compatibility-
# preserving fork of Gitea and the two are deliberately NOT distinguished
# anywhere in this contract. Any other host -- including a GitHub Enterprise
# Server host on a company-owned domain -- prints "unknown"; never guesses.
_detect_forge_classify_host() {
  local host="$1"
  case "$host" in
    github.com|*.github.com) printf 'github' ;;
    gitlab.com|*.gitlab.com) printf 'gitlab' ;;
    gitea.com|*.gitea.com|codeberg.org|*.codeberg.org) printf 'gitea' ;;
    *) printf 'unknown' ;;
  esac
}

# Implements the remote-precedence rule using only local reads -- `git
# remote` to list configured remote names, `git remote get-url <name>` to
# read a URL -- never `git remote show`, which dials the remote over the
# network (the same lesson _resolve_default_branch already paid for; see its
# "requires network" comment above). Precedence: an `origin` remote always
# wins outright, even when it disagrees with every other configured remote;
# else exactly one remote (any name) wins; else zero remotes is a distinct
# outcome ("no-remote") from two-or-more disagreeing remotes ("ambiguous-
# remotes", forge always unknown) -- never resolved by picking `git remote`'s
# listing order. Emits {remote, remoteUrl, source} as three plain-text lines
# -- remote name, source, remote URL, in that order -- and spawns no jq
# process to move them, so _detect_forge_type below can reach this
# precedence rule for free. The URL is deliberately LAST: a pathological
# remote URL carrying an embedded newline can then only truncate itself,
# never shift the two fields classification actually branches on.
#
# This is the single implementation of the precedence rule.
# _detect_forge_select_remote below is a thin JSON-wrapping shim over it, so
# the jq-free and JSON-emitting paths can never drift into two subtly
# different answers to the same question.
_detect_forge_select_remote_raw() {
  local remotes remote_count remote_name="" remote_url="" source=""
  remotes=$(git remote 2>/dev/null) || remotes=""

  if [ -n "$remotes" ] && printf '%s\n' "$remotes" | grep -qx "origin"; then
    remote_name="origin"
    remote_url=$(git remote get-url origin 2>/dev/null) || remote_url=""
    source="remote"
  else
    remote_count=0
    if [ -n "$remotes" ]; then
      remote_count=$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')
    fi
    if [ "$remote_count" -eq 0 ]; then
      source="no-remote"
    elif [ "$remote_count" -eq 1 ]; then
      remote_name="$remotes"
      remote_url=$(git remote get-url "$remote_name" 2>/dev/null) || remote_url=""
      source="remote"
    else
      source="ambiguous-remotes"
    fi
  fi

  printf '%s\n%s\n%s\n' "$remote_name" "$source" "$remote_url"
}

# Reads _detect_forge_select_remote_raw's three lines back into three
# caller-named variables. A plain `IFS= read` loop rather than `$(...)` plus
# parameter expansion, because command substitution strips trailing
# newlines: an empty remote URL would collapse "third line, empty" into "no
# third line at all" and slide `source` into the URL slot.
#
# Internals are _dsr_-prefixed so a caller's own remote/source/url locals can
# never shadow the name-reference targets -- the same collision
# _forge_capture's _fc_ prefixes exist to prevent.
# Usage: _detect_forge_read_selection <name_var> <source_var> <url_var>
_detect_forge_read_selection() {
  local -n _dsr_name="$1" _dsr_source="$2" _dsr_url="$3"
  _dsr_name=""
  _dsr_source=""
  _dsr_url=""

  local _dsr_line _dsr_i=0
  while IFS= read -r _dsr_line; do
    case "$_dsr_i" in
      0) _dsr_name="$_dsr_line" ;;
      1) _dsr_source="$_dsr_line" ;;
      2) _dsr_url="$_dsr_line" ;;
    esac
    _dsr_i=$((_dsr_i + 1))
  done < <(_detect_forge_select_remote_raw)
}

# Unchanged public contract: the {remote, remoteUrl, source} JSON object
# _detect_forge already consumes, byte-identical to what this function
# emitted before it was split. All it does now is wrap the raw helper's
# three values -- the precedence logic itself lives there.
_detect_forge_select_remote() {
  local remote_name remote_url source
  _detect_forge_read_selection remote_name source remote_url

  jq -nc \
    --arg remote "$remote_name" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Strips embedded userinfo credentials (user:pass@ or user@) from an http(s)
# remote URL's authority before it is echoed back in detect-forge's JSON
# output -- a secret must never round-trip through CLI stdout/logs. No-op on
# any other scheme (in particular ssh://, whose leading "user@" is a literal
# SSH login user such as "git@", never a credential -- the same reason git's
# scp-like [user@]host:path form is left untouched below) and on a URL
# carrying no userinfo at all.
_detect_forge_redact_userinfo() {
  local url="$1" scheme scheme_lc rest authority path
  if [[ "$url" != *"://"* ]]; then
    printf '%s' "$url"
    return 0
  fi

  scheme="${url%%://*}"
  # URL schemes are case-insensitive (RFC 3986 s3.1), so match on a lowered
  # copy -- an "HTTPS://" remote must be redacted exactly like "https://".
  # $scheme itself keeps its original case for the printf below, so
  # redaction never silently rewrites the caller's URL beyond the credential
  # it was asked to strip.
  scheme_lc=$(printf '%s' "$scheme" | tr 'A-Z' 'a-z')
  case "$scheme_lc" in
    http|https) ;;
    *)
      printf '%s' "$url"
      return 0
      ;;
  esac

  rest="${url#*://}"
  if [[ "$rest" == *"/"* ]]; then
    authority="${rest%%/*}"
    path="/${rest#*/}"
  else
    authority="$rest"
    path=""
  fi

  if [[ "$authority" == *"@"* ]]; then
    authority="${authority##*@}"
  fi

  printf '%s://%s%s' "$scheme" "$authority" "$path"
}

# Composes the final {forge, host, remote, remoteUrl, source} object.
# AIMI_FORGE_TYPE (already validated by the caller, cmd_detect_forge) short-
# circuits before any git command runs at all when set and non-empty --
# source=override, host/remote/remoteUrl all null. Otherwise selects a
# remote per _detect_forge_select_remote; only when that selection actually
# chose a URL (source=="remote") does it classify the host and redact
# embedded userinfo before echoing the URL back. detect-forge is per-
# repository and is NEVER cached via read_state/write_state -- a multi-repo
# AIMI_ROOT can legitimately mix a GitHub repo and a self-hosted GitLab repo
# under sibling --project calls, and any cache would go stale the moment a
# remote is repointed.
_detect_forge() {
  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    jq -nc --arg forge "$AIMI_FORGE_TYPE" \
      '{forge: $forge, host: null, remote: null, remoteUrl: null, source: "override"}'
    return 0
  fi

  local selection remote remote_url source forge="unknown" host=""
  selection=$(_detect_forge_select_remote)
  remote=$(printf '%s' "$selection" | jq -r '.remote // ""')
  remote_url=$(printf '%s' "$selection" | jq -r '.remoteUrl // ""')
  source=$(printf '%s' "$selection" | jq -r '.source')

  if [ "$source" = "remote" ] && [ -n "$remote_url" ]; then
    host=$(_detect_forge_parse_host "$remote_url")
    forge=$(_detect_forge_classify_host "$host")
    remote_url=$(_detect_forge_redact_userinfo "$remote_url")
  fi

  jq -nc \
    --arg forge "$forge" \
    --arg host "$host" \
    --arg remote "$remote" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{forge: $forge,
      host: (if $host == "" then null else $host end),
      remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Per-process memo behind _detect_forge_type, keyed on the working directory
# each answer was derived in.
#
# KEYED, NOT GLOBAL, AND THAT DISTINCTION IS THE WHOLE POINT: a multi-repo
# AIMI_ROOT is a plain non-git parent holding one git repository per
# subfolder (see CLAUDE.md's Multi-Repo Execution Layout), and those
# siblings can legitimately be a GitHub repo and a GitLab repo. One process
# visiting both must get two answers. A single-slot cache would degrade into
# "whichever repository was classified most recently" and silently report
# github for the gitlab sibling -- the exact leak _detect_forge's own
# "NEVER cached" header comment exists to prevent, reintroduced by the back
# door. That comment is about a PERSISTED cache (read_state/write_state,
# which survives a repointed remote); this memo lives and dies with one
# invocation and is never written to disk.
declare -gA _DETECT_FORGE_TYPE_MEMO

# The forge word alone -- github|gitlab|gitea|unknown -- for the callers
# that need only that and threw the rest of _detect_forge's envelope away.
# No JSON is built or parsed anywhere on this path: it reaches the same
# precedence rule through _detect_forge_select_remote_raw and the
# already-pure-bash _detect_forge_parse_host/_detect_forge_classify_host, so
# a derivation costs the two `git remote` reads and nothing else.
#
# WHO DOES *NOT* USE THIS, AND WHY: _forge_repo_info and _forge_auth_status
# read `host`/`remoteUrl` out of the envelope, and so -- since US-004 grew
# the shared failure classifier -- do _forge_issue_view,
# _forge_pr_review_threads and _forge_resolve_review_thread, each of which
# now hands `host` to _forge_classify_gh_failure_reason. This function
# carries no host, so all five deliberately keep their full _detect_forge
# call. Widening the memo to the whole envelope would serve them too and is
# a reasonable follow-up, but it is a different change from this one.
#
# OUT-PARAMETER, NOT STDOUT, AND THAT IS LOAD-BEARING: a printed answer
# forces every call site into `forge=$(_detect_forge_type)`, whose command
# substitution forks a subshell -- and a memo populated inside a subshell
# dies with it, leaving every call site a full derivation again. Writing
# through a name reference keeps the memo in the ONE process that will reuse
# it. Subshells forked later (`existing=$(cmd_forge_pr_view ...)` inside
# _forge_pr_create) inherit the populated array and read it as a hit, which
# is what collapses a create-a-new-PR run from three derivations to one.
#
# AIMI_FORGE_TYPE short-circuits before the memo as well as before any git
# command: it is already a zero-cost stateless read, and it is deliberately
# NOT validated here, mirroring _detect_forge's own override precedent above
# (cmd_detect_forge validates it once, and internal callers already trust
# the value unvalidated through _detect_forge).
#
# Internals are _dft_-prefixed so a caller's own `forge` local can never
# shadow the name-reference target.
# Usage: _detect_forge_type <forge_var>
_detect_forge_type() {
  local -n _dft_out="$1"

  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    _dft_out="$AIMI_FORGE_TYPE"
    return 0
  fi

  # $PWD, deliberately, rather than a subshelled `pwd -P`: every cmd_forge_*
  # wrapper's --project handling cd's into its final working directory
  # exactly once, before any forge derivation runs, so $PWD is stable and
  # correct for the whole remaining lifetime of the invocation at zero fork
  # cost.
  local _dft_key="$PWD"
  if [ -n "${_DETECT_FORGE_TYPE_MEMO[$_dft_key]+set}" ]; then
    _dft_out="${_DETECT_FORGE_TYPE_MEMO[$_dft_key]}"
    return 0
  fi

  local _dft_name _dft_source _dft_url _dft_forge="unknown"
  _detect_forge_read_selection _dft_name _dft_source _dft_url

  if [ "$_dft_source" = "remote" ] && [ -n "$_dft_url" ]; then
    _dft_forge=$(_detect_forge_classify_host "$(_detect_forge_parse_host "$_dft_url")")
  fi

  _DETECT_FORGE_TYPE_MEMO["$_dft_key"]="$_dft_forge"
  _dft_out="$_dft_forge"
}

# Detect the forge (github|gitlab|gitea|unknown) for the active git remote.
# AIMI_FORGE_TYPE overrides detection entirely and must be one of
# github|gitlab|gitea, validated here -- before _detect_forge ever runs --
# so an invalid value never reaches a git command. Never cached (see
# _detect_forge's header comment: per-repository, per-invocation).
cmd_detect_forge() {
  check_jq

  local project_dir=""

  # Parse --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    case "$AIMI_FORGE_TYPE" in
      github|gitlab|gitea) ;;
      *)
        echo "Error: detect-forge: unrecognized AIMI_FORGE_TYPE value: $AIMI_FORGE_TYPE (expected one of: github, gitlab, gitea)" >&2
        exit 1
        ;;
    esac
  fi

  _detect_forge
}

# Normalize a single %D decoration token for parent-branch detection.
# Pipeline: (1) strip an "X -> Y" arrow decoration, keeping the right-hand
# side (covers "HEAD -> <branch>" and, defensively, "origin/HEAD ->
# origin/<branch>"); (2) drop a bare HEAD token; (3) drop a tag: -prefixed
# token; (4) strip a leading origin/ remote-tracking prefix; (5) re-check
# for a bare HEAD token now that origin/ has been stripped (catches
# "origin/HEAD" -> "HEAD"); (6) drop the token if it is now empty or equals
# the branch being examined exactly -- exact match only, never a substring
# match (this is the DEFECT 3 fix for the old grep -v "$CURRENT_BRANCH").
# Prints the surviving token, or nothing when the token was dropped.
_normalize_decoration_token() {
  local token="$1" branch="$2"

  # (1) Arrow decoration: keep the right-hand side.
  if [[ "$token" == *" -> "* ]]; then
    token="${token#*" -> "}"
  fi

  # (2) Bare HEAD (detached-HEAD marker, or the left side of an
  #     already-stripped arrow that somehow left just HEAD).
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (3) Tag refs are never a parent-branch candidate.
  if [[ "$token" == "tag: "* ]]; then
    return 0
  fi

  # (4) Strip the remote-tracking prefix.
  if [[ "$token" == "origin/"* ]]; then
    token="${token#origin/}"
  fi

  # (5) Re-check for HEAD now that origin/ has been stripped.
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (6) Exact-match-only drop: empty token, or the token IS the branch
  #     we're examining (its own tip decoration). Never a substring check.
  if [ -z "$token" ] || [ "$token" = "$branch" ]; then
    return 0
  fi

  printf '%s' "$token"
}

# Walk branch's --first-parent decoration history (git log --pretty=format:'%D')
# token-by-token, nearest ancestor first, and return the first surviving
# candidate parent-branch name after _normalize_decoration_token. Prints
# nothing when no candidate survives across the whole history.
# Emits EVERY decoration candidate in --first-parent walk order, one per
# line, deduplicated -- not just the first. The caller verifies them in that
# order and takes the first that survives merge-base.
#
# WHY THIS EMITS A LIST RATHER THAN ONE VALUE. It used to return the first
# token that normalized and stop there, with verification happening
# afterwards in the caller. A rejected first candidate therefore ended the
# search: not the next token on the same line, not the next commit, straight
# to the default branch. Reproduced: a leftover story-branch ref pointing at
# the same tip as the branch being resolved is normalized (its name differs),
# then rejected by the caller's own "candidate must not be the branch's own
# tip" rule -- and a genuine parent nine commits further down, carrying a
# valid decoration, was never consulted. detect-parent-branch answered
# `main`/unverified for a branch cut from a feature branch; removing that one
# ref made it answer correctly with nothing else changed. A search that
# discards a candidate without resuming is not a search.
_detect_parent_branch_candidate() {
  local branch="$1"
  local log_output
  log_output=$(git log "$branch" --pretty=format:'%D' --first-parent 2>/dev/null) || true

  local line raw_token normalized seen=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local -a tokens
    local old_ifs="$IFS"
    IFS=','
    read -ra tokens <<< "$line"
    IFS="$old_ifs"

    for raw_token in "${tokens[@]}"; do
      # Decoration tokens are separated by ", " -- trim the leading space.
      raw_token="${raw_token# }"
      normalized=$(_normalize_decoration_token "$raw_token" "$branch")
      [ -n "$normalized" ] || continue
      # Dedupe: the same branch name can decorate more than one commit on the
      # walk, and re-verifying it would cost a git call per repeat.
      case "$seen" in
        *"|${normalized}|"*) continue ;;
      esac
      seen="${seen}|${normalized}|"
      printf '%s\n' "$normalized"
    done
  done <<< "$log_output"
}

# Verify a decoration candidate is a genuine ancestor of branch via
# git merge-base, rejecting a divergent sibling whose ref happens to share
# the candidate's (post-normalization) name. Resolves the candidate against
# a local branch first, falling back to an origin-prefixed remote-tracking
# ref only when no local branch of that name exists.
_verify_parent_candidate() {
  local branch="$1" candidate="$2"
  local candidate_ref candidate_commit branch_commit merge_base

  if candidate_commit=$(git rev-parse --verify "${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="$candidate"
  elif candidate_commit=$(git rev-parse --verify "origin/${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="origin/${candidate}"
  else
    return 1
  fi

  branch_commit=$(git rev-parse --verify "${branch}^{commit}" 2>/dev/null) || return 1

  # The candidate must not be the branch's own tip commit.
  if [ "$candidate_commit" = "$branch_commit" ]; then
    return 1
  fi

  # The candidate must be a genuine ancestor of branch (its own commit is
  # the merge base), not a divergent sibling.
  merge_base=$(git merge-base "$branch" "$candidate_ref" 2>/dev/null) || return 1

  [ "$merge_base" = "$candidate_commit" ]
}

# Detect a branch's parent (base) branch by parsing its --first-parent git
# log decorations token-by-token (replacing the old grep -v line-filtering
# pipeline in commands/open-pr.md, which mishandled "HEAD -> <parent>" and
# substring-alike branch names) and confirming the candidate with
# git merge-base. Falls back to the repository's default branch (unverified)
# when no decoration candidate survives normalization or merge-base
# verification.
# Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]
# Output: {"branch":<input>,"base":<resolved>,"verified":<bool>,"source":"decoration"|"default-branch"}
cmd_detect_parent_branch() {
  local branch="" project_dir=""

  # Parse positional branch arg + --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        if [ -z "$branch" ]; then
          branch="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$branch" ]; then
    echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security) — before any git command uses it
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  local raw_candidate
  local base="" verified="false" source="default-branch"

  # Try every candidate in walk order and take the first that verifies. A
  # rejected candidate no longer ends the search -- see
  # _detect_parent_branch_candidate's header for what that cost.
  while IFS= read -r raw_candidate; do
    [ -n "$raw_candidate" ] || continue
    if _verify_parent_candidate "$branch" "$raw_candidate"; then
      base="$raw_candidate"
      verified="true"
      source="decoration"
      break
    fi
  done <<< "$(_detect_parent_branch_candidate "$branch")"

  if [ -z "$base" ]; then
    base=$(_resolve_default_branch)
  fi

  jq -nc \
    --arg branch "$branch" \
    --arg base "$base" \
    --argjson verified "$verified" \
    --arg source "$source" \
    '{branch: $branch, base: $base, verified: $verified, source: $source}'
}

# ============================================================================
# Forge Contract — shared builders and degradation helper (US-002)
# ============================================================================
# This section delivers two artifacts this phase's roadmap declares under
# creates[], each named here verbatim on its own line so a text search finds
# the identity intact rather than split across a wrapped comment:
#
# normalized PR and issue field contract
#
# forge degradation contract (missing adapter or missing CLI prints a manual instruction)
#
# Full documentation, including the state-mapping table, capability-gated
# field tables, the review/approval envelope rationale, the three-way status
# convention, and the credential/identity model, lives in
# commands/references/forge-contract.md — this section implements exactly
# what that document specifies, nothing more.
#
# forge-contract.md is the SINGLE ARBITER of the vocabulary below. No later
# forge-* verb may introduce a variant field-name casing (e.g. camelCase
# unsupportedFields) or a second degradation signal (e.g. a degradedReason
# field alongside status) — see that file's opening section for the full
# statement.
#
# This section introduces NO gh/glab/tea invocation, no git-remote parsing,
# and no forge-pr-view/forge-auth-status/forge-repo-info verb body. Those
# belong to later stories in this phase, which call the functions below
# rather than re-deriving the shapes they build.

# Shared jq -nc builder for the normalized PR object (forge-contract.md
# "Normalized PR Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state, --head-ref-name, --base-ref-name) are always
# accepted and null when empty. Capability-gated fields (--files, a JSON
# array; --is-draft, JSON true/false; --mergeable, a raw string — never
# forced to boolean, since GitLab's detailed_merge_status is a 16-value
# enum) are tracked by FLAG PRESENCE, not by value: omitting the flag is
# what marks a field unsupported, regardless of what value would otherwise
# have been passed. Every omitted capability-gated field comes back null
# AND its name is appended to unsupported_fields — never a bare, unmarked
# null. --raw carries the untouched forge-native object alongside the
# normalized shape (JSON object/array/literal, defaults to null).
_forge_build_pr_json() {
  local number="" url="" title="" body="" state="" head_ref="" base_ref=""
  local files_json="null" is_draft_json="null" mergeable="" raw="null"
  local files_set=false is_draft_set=false mergeable_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)         shift; number="${1:-}" ;;
      --url)            shift; url="${1:-}" ;;
      --title)          shift; title="${1:-}" ;;
      --body)           shift; body="${1:-}" ;;
      --state)          shift; state="${1:-}" ;;
      --head-ref-name)  shift; head_ref="${1:-}" ;;
      --base-ref-name)  shift; base_ref="${1:-}" ;;
      --files)          shift; files_json="${1:-null}"; files_set=true ;;
      --is-draft)       shift; is_draft_json="${1:-null}"; is_draft_set=true ;;
      --mergeable)      shift; mergeable="${1:-}"; mergeable_set=true ;;
      --raw)            shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_pr_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$files_set" = true ]     || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["files"]')
  [ "$is_draft_set" = true ]  || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["isDraft"]')
  [ "$mergeable_set" = true ] || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["mergeable"]')

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --arg headRefName "$head_ref" \
    --arg baseRefName "$base_ref" \
    --argjson files "$files_json" \
    --argjson isDraft "$is_draft_json" \
    --arg mergeable "$mergeable" \
    --argjson mergeableSet "$mergeable_set" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      headRefName: (if $headRefName == "" then null else $headRefName end),
      baseRefName: (if $baseRefName == "" then null else $baseRefName end),
      files: $files,
      isDraft: $isDraft,
      mergeable: (if $mergeableSet and ($mergeable != "") then $mergeable else null end),
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared jq -nc builder for the normalized issue object (forge-contract.md
# "Normalized Issue Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state) are always accepted and null when empty. The
# one capability-gated field (--comments, a JSON int) is tracked by flag
# presence exactly like _forge_build_pr_json's capability-gated fields.
# --raw carries the untouched forge-native object (defaults to null).
_forge_build_issue_json() {
  local number="" url="" title="" body="" state="" raw="null"
  local comments_json="null" comments_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)   shift; number="${1:-}" ;;
      --url)      shift; url="${1:-}" ;;
      --title)    shift; title="${1:-}" ;;
      --body)     shift; body="${1:-}" ;;
      --state)    shift; state="${1:-}" ;;
      --comments) shift; comments_json="${1:-null}"; comments_set=true ;;
      --raw)      shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_issue_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$comments_set" = true ] || unsupported='["comments"]'

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --argjson comments "$comments_json" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      comments: $comments,
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared three-way status envelope (forge-contract.md "Three-Way Status
# Convention"), modeled directly on roadmap.py's verify_creates_one verdict shape's own
# verified/missing/error trio: found/not_found/error are three genuinely
# distinct outcomes and must never be conflated the way `gh pr view --json
# url` today exits non-zero for both "no PR exists" and "auth/network
# broken". Every later forge lookup verb constructs its result through this
# one function instead of hand-rolling the JSON assembly per verb.
#
# Usage: _forge_emit_status <status> [data-json] [message] [reason]
#   status   found | not_found | error -- anything else is a caller error
#            (unknown status, exit 1) rather than silently coerced.
#   data     JSON value (typically a normalized PR/issue object). Forced to
#            null unless status == "found", so a caller cannot accidentally
#            leak a stale value across the wrong branch of the outcome.
#   message  the human-readable degraded reason -- prose for a log or a
#            person. Forced to null unless status == "error".
#   reason   the MACHINE-readable degraded reason: a fixed, closed enum
#            (no_adapter | cli_missing | not_authenticated | cli_failed,
#            forge-contract.md "Degradation Reason Enum"), so a caller
#            branches on a stable value instead of grepping translatable
#            English out of `message`. Any other non-empty value is a caller
#            error (exit 1) -- the identical discipline `status` above
#            already gets, rather than silently passing an unknown value
#            through to a caller that would then branch on it. Forced to
#            null unless status == "error", exactly like `message`, so a
#            stale reason can never ride along on a found/not_found result.
#            It exists ALONGSIDE `message`, never as a replacement for it.
_forge_emit_status() {
  local status="$1" data_json="${2:-null}" message="${3:-}" reason="${4:-}"

  case "$status" in
    found|not_found|error) ;;
    *)
      echo "Error: _forge_emit_status: status must be found, not_found or error (got: $status)" >&2
      return 1
      ;;
  esac

  case "$reason" in
    ""|no_adapter|cli_missing|not_authenticated|cli_failed) ;;
    *)
      echo "Error: _forge_emit_status: reason must be no_adapter, cli_missing, not_authenticated or cli_failed (got: $reason)" >&2
      return 1
      ;;
  esac

  if [ "$status" != "found" ]; then
    data_json="null"
  fi
  if [ "$status" != "error" ]; then
    message=""
    reason=""
  fi

  jq -nc \
    --arg status "$status" \
    --argjson data "$data_json" \
    --arg message "$message" \
    --arg reason "$reason" \
    '{status: $status,
      data: $data,
      message: (if $message == "" then null else $message end),
      reason: (if $reason == "" then null else $reason end)}'
}

# Shared WRITE-verb status envelope (forge-contract.md "Write-Verb Status
# Convention") -- the exact sibling of _forge_emit_status above: identical
# {status, data, message} field names and identical null-forcing
# discipline, differing ONLY in which three values `status` may take.
#
# A write has no "not found" outcome (nothing was looked up), so forcing
# the read side's found/not_found/error trio onto forge-pr-create/
# forge-pr-edit/forge-issue-create would be a bad fit -- but letting each
# of those three verbs hand-roll its own shape (a bare {url, number,
# created} boolean here, a flat {url, number, status, message} there, a
# status-less {url, number} somewhere else) was worse: a caller then had to
# branch on field presence, on a per-verb vocabulary, or on the exit code
# alone to learn what a write actually did.
#
# Usage: _forge_emit_write_status <status> [data-json] [message]
#   status   created | unchanged | degraded -- anything else is a caller
#            error (exit 1) rather than silently coerced, mirroring
#            _forge_emit_status's own guard.
#              created   -- a new resource identifier was minted.
#              unchanged -- no new identifier was minted. Covers both
#                           forge-pr-create finding an already-open PR and
#                           every successful forge-pr-edit call, which only
#                           ever mutates an existing number.
#              degraded  -- the write could not complete automatically;
#                           `message` carries the reason.
#   data     JSON value (typically {url, number}). Forced to null unless
#            status is "created" or "unchanged", so a caller cannot
#            accidentally leak a stale identifier across a degraded branch.
#   message  the one and only degraded-reason field in this contract.
#            Forced to null unless status == "degraded".
#
# This envelope is an ADDITION to each verb's exit-code contract, never a
# replacement for it: forge-pr-create/forge-pr-edit still exit non-zero on
# every degraded outcome, and forge-issue-create still exits 0 on all of
# them (see the EXIT CONTRACT DIFFERS comment in the pr-write section).
_forge_emit_write_status() {
  local status="$1" data_json="${2:-null}" message="${3:-}"

  case "$status" in
    created|unchanged|degraded) ;;
    *)
      echo "Error: _forge_emit_write_status: status must be created, unchanged or degraded (got: $status)" >&2
      return 1
      ;;
  esac

  if [ "$status" != "created" ] && [ "$status" != "unchanged" ]; then
    data_json="null"
  fi
  if [ "$status" != "degraded" ]; then
    message=""
  fi

  jq -nc \
    --arg status "$status" \
    --argjson data "$data_json" \
    --arg message "$message" \
    '{status: $status, data: $data, message: (if $message == "" then null else $message end)}'
}

# Builds the {url, number} object every write verb nests under the write
# envelope's `data` key. One builder for all three verbs, so their success
# shapes are identical BY CONSTRUCTION rather than by three hand-rolled jq
# expressions that merely happen to agree today.
# Usage: _forge_build_write_data <url> [number]
#   url     empty -> null.
#   number  empty -> null, otherwise a JSON int (never a quoted string).
_forge_build_write_data() {
  local url="${1:-}" number="${2:-}"
  jq -nc \
    --arg url "$url" \
    --arg number "$number" \
    '{url: (if $url == "" then null else $url end),
      number: (if $number == "" then null else ($number | tonumber) end)}'
}

# Shared graceful-degradation gate (forge-contract.md "Degradation
# Contract") for every forge-* verb that shells out to a forge CLI
# (gh/glab/tea). `command -v` is a portable presence check that never
# invokes the binary, so it cannot itself hang, prompt, or leak an
# unguarded 127 -- guarding here is the whole point of this function.
#
# Usage: _forge_bin_check <binary> <quiet|mandatory> <forge-label>
#   Returns 0 when <binary> resolves on PATH, 1 otherwise -- in BOTH modes.
#   quiet mode:     absence produces NO stderr output at all. For a caller
#                   that already has its own fallback path and would only
#                   restate it -- matches review.md's documented row ("gh
#                   CLI not installed -> Fall back to git diff for branch
#                   comparison"), which must not gain a spurious warning it
#                   does not have today.
#   mandatory mode: absence prints exactly ONE stderr warning naming the
#                   missing binary, the forge label the caller passed (from
#                   detect-forge's output -- never a generic placeholder),
#                   and a manual next step -- matches execute.md's existing
#                   `command -v gh` gate at the per-repository PR-creation
#                   step.
_forge_bin_check() {
  local binary="$1" mode="$2" forge_label="$3"

  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$mode" = "mandatory" ]; then
    echo "Warning: $binary not found -- this $forge_label operation cannot run automatically; install $binary or complete it manually." >&2
  fi
  return 1
}

# Runs a command with its stdout, stderr and exit status captured into three
# caller-named variables, guaranteeing the stderr scratch file is removed on
# every return path. Seven gh adapters below each carried their own
# mktemp/capture/cat/rm copy of this, every one of them relying on the next
# editor remembering to keep the `rm -f` as the last line.
#
# Usage -- ALWAYS a plain statement, NEVER inside $(...):
#   _forge_capture <stdout_var> <stderr_var> <rc_var> -- <cmd> [args...] || true
#
# The trailing `|| true` is MANDATORY under this file's `set -e`: this function
# returns the wrapped command's own exit status, so a legitimate non-zero gh
# exit would otherwise abort the whole CLI. The real status is always readable
# from <rc_var>, which is what all seven callers branch on. A `$(...)` wrapper
# would fork a subshell, where a name-reference write cannot reach the caller's
# variables and the exit status is discarded -- hence "plain statement".
#
# The RETURN trap DISARMS ITSELF, and that is load-bearing rather than
# decorative: bash's RETURN trap is a shell-global, not a function-scoped one.
# Left armed it fires a second time on the CALLER's own return, by which point
# $_fc_err_file is out of scope -- a hard `unbound variable` abort under
# `set -u`. Verified empirically both ways; the self-disarming form fires
# exactly once per call, on whichever return path this function takes,
# including a future early return nobody has written yet. It is not inherited
# by nested calls (no `set -T`/functrace in this file), and the one nested
# substitution any caller passes -- `-f query="$(_forge_review_threads_query)"`
# -- is evaluated in the caller's own shell before this function is entered.
#
# Internals are _fc_-prefixed so a caller's own stdout/stderr/stderr_out/rc
# locals can never collide with the name-reference targets.
_forge_capture() {
  local -n _fc_out="$1" _fc_err="$2" _fc_rc="$3"
  shift 3
  if [ "${1:-}" = "--" ]; then shift; fi

  local _fc_err_file
  _fc_err_file=$(mktemp) || exit 1
  trap 'rm -f "$_fc_err_file"; trap - RETURN' RETURN

  _fc_rc=0
  _fc_out=$("$@" 2>"$_fc_err_file") || _fc_rc=$?
  _fc_err=$(cat "$_fc_err_file" 2>/dev/null || true)
  return "$_fc_rc"
}

# Classifies an ALREADY-FAILED gh invocation into forge-contract.md's
# Degradation Reason Enum, printing exactly one of `not_authenticated` or
# `cli_failed`. One shared helper so every adapter below asks the question
# the same way instead of each duplicating its own check.
#
# Usage: _forge_classify_gh_failure_reason <host>
#
# The answer is determined STRUCTURALLY, never by pattern-matching the
# failing command's own stderr text: this calls _forge_auth_status_github
# directly (a function call, never a `$AIMI_CLI forge-auth-status`
# subprocess -- the exact primitive the shipped forge-auth-status verb uses
# to answer this same question) and reads its `.authenticated` field. Note
# that `.authenticated` is the field that answers "is the user logged in";
# _forge_emit_status's own `status` field answers only "did the check run",
# which is a different question and the wrong one to branch on here.
#
# Why structural rather than a stderr match on gh's known auth-failure
# wording ("HTTP 401", "Bad credentials", "gh auth login"): that wording can
# be reworded on any gh release and varies by locale, so a match silently
# stops matching and misclassifies every future auth failure as cli_failed.
# forge-pr-view's not_found detection was made structural for exactly this
# reason; this follows that precedent rather than _forge_issue_view's
# unremediated stderr match.
#
# COST AND ORDERING: the one extra `gh auth status` round trip happens only
# on an already-failed request, and only after the CALLING adapter has
# already confirmed gh is on PATH through its own separate _forge_bin_check
# gate. cli_missing is therefore always ruled out before this ever runs --
# the two reasons can never collide.
#
# Anything short of a definite "authenticated: false" resolves to
# cli_failed, including a call that could not determine an active account at
# all: this classifier only ever narrows an already-known failure, so the
# catch-all is the safe direction.
_forge_classify_gh_failure_reason() {
  local host="${1:-}"
  local auth_json="" authenticated=""

  auth_json=$(_forge_auth_status_github "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""

  if [ "$authenticated" = "false" ]; then
    printf '%s' "not_authenticated"
    return 0
  fi

  printf '%s' "cli_failed"
}

# Prints the gh token this repository's REMEMBERED ACCOUNT should act as for
# ONE forge invocation, or the empty string. Always exits 0. Writes nothing,
# anywhere: no `gh auth switch`, no hosts.yml, no file on disk.
#
# Usage -- ALWAYS a bash PREFIX ASSIGNMENT on the wrapped call, NEVER `env`:
#   GH_TOKEN="$(_forge_account_override GH_TOKEN)" \
#   GH_ENTERPRISE_TOKEN="$(_forge_account_override GH_ENTERPRISE_TOKEN)" \
#     _forge_capture stdout stderr_out rc -- gh pr create --title "$title" ... || true
#
# BOTH SLOTS ARE WRITTEN LITERALLY, AT MOST ONE IS EVER NON-EMPTY. Bash cannot
# prefix-assign a dynamically named variable, so the call site names both and
# passes the name it is filling; this function decides which one gets a value
# and returns empty for the other. gh treats an EMPTY token variable as unset
# (verified, gh 2.94.0), which is why the "always use whichever account is
# active" opt-out and the no-answer case reuse the identical call-site shape
# with no separate branch anywhere.
#
# `export` IS FORBIDDEN; THE OVERRIDE IS A PREFIX ASSIGNMENT ON ONE COMMAND,
# ALWAYS. That rule is load-bearing, not stylistic. Under a process-wide
# GH_TOKEN, `gh auth status` reports the ENV-TOKEN account as
# "Active account: true" -- so _forge_auth_status_github's parser below would
# start reporting the overridden account as the machine's active one, and the
# very before/after check that proves the machine account was left alone would
# become unable to detect a violation. A prefix assignment on a FUNCTION
# invocation is set inside the function, exported into the `gh` grandchild it
# spawns, and unset again the moment the function returns, so _forge_capture
# needs no signature change and nothing survives the call.
#
# NO TOKEN EVER REACHES argv. The `env GH_TOKEN=... gh ...` shape is banned for
# exactly this reason -- env(1)'s own argv carries the value and leaks it
# through `ps`. Nothing here echoes, logs or emits the token either: it is this
# function's stdout value and nothing else. Same bar phase 1 already holds with
# _detect_forge_redact_userinfo, which strips embedded userinfo from a remote
# URL before it can round-trip through this CLI's stdout.
#
# HOST DECIDES THE VARIABLE NAME, AND GETTING IT WRONG FAILS SILENTLY:
# gh honors GH_TOKEN for github.com and *.ghe.com ONLY; a GitHub Enterprise
# Server host on a company domain needs GH_ENTERPRISE_TOKEN instead
# (`gh help environment`). Emitting GH_TOKEN at a GHES host does not error --
# it is ignored, and the write succeeds attributed to the WRONG ACCOUNT, which
# is the worst available outcome. The mapping:
#
#   github.com, *.github.com   -> GH_TOKEN             --hostname <host>
#   ghe.com, *.ghe.com         -> GH_TOKEN             --hostname <host>
#   any other non-empty host   -> GH_ENTERPRISE_TOKEN  --hostname <host>
#   empty / unresolvable host  -> GH_TOKEN             --hostname omitted entirely
#
# The empty-host row is the AIMI_FORGE_TYPE override path, where _detect_forge
# emits host: null and there is no hostname to pass; gh then uses its own
# default host. The host is derived through _forge_account_host_cached below --
# the jq-free _detect_forge_read_selection + _detect_forge_parse_host pair (two
# `git remote` reads on a memo miss, zero jq processes) -- rather than taken
# from the caller, because three of the four write paths reach identity through
# _detect_forge_type, which by its own header comment carries no host at all.
# That pair returns a lowercased
# plain string and can never produce the four-character text "null" the way a
# bare `jq -r '.host'` can -- the defect commit d1b19ca paid for, where "null"
# reached --hostname and its refusal read as a confirmed not-authenticated
# answer. Every jq read below uses `// empty` for the same reason.
#
# COST. The requested-name check happens BEFORE any gh call and before the
# store is read, so the non-matching slot costs nothing at all and one routed
# write costs exactly ONE `gh auth token` process, never two. The opt-out and
# the no-answer case cost zero gh processes.
#
# Precedence, highest first -- the same env-over-stored convention
# AIMI_FORGE_TYPE already sets for detection:
#   1. AIMI_FORGE_IDENTITY, when non-empty
#   2. the account cmd_forge_account_select recorded for this repository
#   3. nothing -- empty override, the machine's active account acts
# The store holds a LOGIN, never a token. Nothing here persists a token; it is
# minted per invocation and dies with the process.
#
# THE LOOKUP RUNS OUTSIDE ANY OVERRIDE, deliberately: `gh auth token` with a
# GH_TOKEN already in the environment returns THAT token rather than the
# keyring's, so an ambient override would make this function resolve to itself.
# Both variables are cleared for its own call.
#
# DEGRADATION IS DELIBERATE. A remembered account that was later
# `gh auth logout`'d makes `gh auth token --user <login>` exit non-zero
# ("no oauth token found for <host> account <login>"). This prints nothing,
# exits 0, and emits exactly ONE stderr warning naming the login and host --
# never the token, and never gh's own stderr verbatim, which can echo token
# prefixes. The write then proceeds as the machine's active account: the same
# warn-and-fall-back posture _forge_bin_check and _forge_emit_write_status
# already established, with the wrong-account attribution made visible rather
# than the write blocked. Because this is evaluated inside a `$( )` in a prefix
# assignment, the warning goes straight to the user's stderr and is never
# captured into _forge_capture's stderr_out, so it cannot contaminate an
# emitted JSON `message`.
#
# CLASSIFIER SEAM, decided rather than discovered later, and now CLOSED:
# _forge_classify_gh_failure_reason above calls _forge_auth_status_github, so
# left outside the override that call would re-check the MACHINE account's auth
# after a write failed as a DIFFERENT account. It SHOULD run under the same
# override, because with the override applied `gh auth status` reports the
# env-token account, which is exactly the account whose failure is being
# classified. Exactly ONE classifier call sits inside a write path: the one in
# _forge_resolve_review_thread (the
# `reason=$(_forge_classify_gh_failure_reason "$host")` line after its
# could-not-resolve-to-a-node match). The other two -- in _forge_issue_view and
# _forge_pr_review_threads_github -- are pure reads outside this phase's write
# set, and _forge_pr_create/_forge_pr_edit/_forge_issue_create never call it.
# The routing pass carried that one prefix assignment to that one CALL SITE;
# the classifier function itself was never edited, which is what kept the two
# stories off the same function. See the ROUTING RULE block below.
#
# Residual, accepted and named rather than defended against: `bash -x` would
# print the token as part of the prefix-assignment expansion. This file never
# enables xtrace (`set -euo pipefail` only), so that is a debugging-time hazard,
# not a shipped leak.
#
# Per-process memo behind _forge_account_host_cached, keyed on the working
# directory each answer was derived in -- the same shape, and keyed for the same
# multi-repo reason, as _DETECT_FORGE_TYPE_MEMO above.
declare -gA _FORGE_ACCOUNT_HOST_MEMO

# The forge host an override is keyed under: a lowercased plain string, or empty
# when there is none. Two `git remote` reads on a miss, zero on a hit.
#
# OUT-PARAMETER, NOT STDOUT, for precisely _detect_forge_type's reason: a memo
# populated inside a `$(...)` subshell dies with that subshell, and
# _forge_account_override below is ALWAYS called inside one (it is a printer,
# used in a prefix assignment). So the memo is warmed by
# _forge_account_override_slots -- a plain statement in the caller's own shell
# -- and the two `$(...)` lookups it then makes inherit the populated array and
# read it as a hit. Without that warming, one routed write would derive the host
# twice, once per slot, to answer the same question.
#
# Internals are _fahc_-prefixed so _detect_forge_read_selection's name-reference
# targets can never collide with a caller's own locals.
# Usage: _forge_account_host_cached <host_var>
_forge_account_host_cached() {
  local -n _fahc_out="$1"
  _fahc_out=""

  # AIMI_FORGE_TYPE short-circuits before the memo as well as before any git
  # command, mirroring _detect_forge's own override arm, which emits host: null
  # on that path -- there is no host to key anything under.
  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    return 0
  fi

  local _fahc_key="$PWD"
  if [ -n "${_FORGE_ACCOUNT_HOST_MEMO[$_fahc_key]+set}" ]; then
    _fahc_out="${_FORGE_ACCOUNT_HOST_MEMO[$_fahc_key]}"
    return 0
  fi

  local _fahc_name _fahc_source _fahc_url _fahc_host=""
  _detect_forge_read_selection _fahc_name _fahc_source _fahc_url
  if [ "$_fahc_source" = "remote" ] && [ -n "$_fahc_url" ]; then
    _fahc_host=$(_detect_forge_parse_host "$_fahc_url")
  fi

  _FORGE_ACCOUNT_HOST_MEMO["$_fahc_key"]="$_fahc_host"
  _fahc_out="$_fahc_host"
}

# Internals are _fao_-prefixed so _detect_forge_read_selection's name-reference
# targets can never collide with a caller's own locals.
_forge_account_override() {
  local _fao_want="${1:-}"
  [ -n "$_fao_want" ] || return 0

  # Host first -- it decides both the variable name and the store key.
  local _fao_host=""
  _forge_account_host_cached _fao_host

  local _fao_var="GH_TOKEN"
  case "$_fao_host" in
    ""|github.com|*.github.com|ghe.com|*.ghe.com) _fao_var="GH_TOKEN" ;;
    *) _fao_var="GH_ENTERPRISE_TOKEN" ;;
  esac

  # The slot this host does not use costs nothing: no store read, no gh call.
  [ "$_fao_want" = "$_fao_var" ] || return 0

  local _fao_login=""
  if [ -n "${AIMI_FORGE_IDENTITY:-}" ]; then
    _fao_login="$AIMI_FORGE_IDENTITY"
  elif [ -n "$_fao_host" ]; then
    # An answer is keyed by host, so an unresolvable host has nothing to look
    # up. _forge_account_store_path is documented to be allowed to decline.
    local _fao_store="" _fao_entry=""
    _fao_store=$(_forge_account_store_path) || _fao_store=""
    if [ -n "$_fao_store" ]; then
      # _forge_account_stored_entry already validates the mode discriminator
      # and rejects an empty account string, so `null` covers absent, corrupt
      # and not-an-answer alike. mode "active" is the deliberate opt-out and
      # yields empty here -- a real answer, not a missing one.
      _fao_entry=$(_forge_account_stored_entry "$_fao_store" "$_fao_host")
      if [ "$_fao_entry" != "null" ]; then
        _fao_login=$(printf '%s' "$_fao_entry" | jq -r 'if .mode == "account" then (.account // empty) else empty end')
      fi
    fi
  fi

  [ -n "$_fao_login" ] || return 0

  # gh's absence is not this function's diagnosis to make -- the calling write
  # path already gates on _forge_bin_check and says so once. Warning here too
  # would add a second, wrong explanation ("no token for <login>") for a
  # machine that simply has no gh.
  _forge_bin_check gh quiet github || return 0

  local _fao_token="" _fao_rc=0
  if [ -n "$_fao_host" ]; then
    _fao_token=$(GH_TOKEN= GH_ENTERPRISE_TOKEN= gh auth token --user "$_fao_login" --hostname "$_fao_host" 2>/dev/null) || _fao_rc=$?
  else
    _fao_token=$(GH_TOKEN= GH_ENTERPRISE_TOKEN= gh auth token --user "$_fao_login" 2>/dev/null) || _fao_rc=$?
  fi

  if [ "$_fao_rc" -ne 0 ]; then
    echo "Warning: no gh token for account \"$_fao_login\" on host \"${_fao_host:-default}\" -- it may have been logged out; this operation will proceed as the machine active account." >&2
    return 0
  fi

  printf '%s' "$_fao_token"
}

# Fills the caller's TWO prefix-assignment locals for ONE forge invocation.
# Usage -- ALWAYS a plain statement, never inside $(...):
#   local gh_token_override="" ghe_token_override=""
#   _forge_account_override_slots gh_token_override ghe_token_override
#
# This exists so a write function resolves the account ONCE and then names the
# same two locals at every routed command, instead of paying for the derivation
# at each of the three or four gh-facing steps one write makes. It adds NO
# resolution logic of its own: _forge_account_override above remains the single
# place that decides which slot gets a value and what that value is.
#
# AN EMPTY OVERRIDE MUST NOT BLANK AN INHERITED TOKEN. Empty means "nothing was
# recorded for this repository" or the deliberate "always use whichever account
# is active" opt-out -- and in BOTH cases the acting account is whatever gh
# would have used on its own, which includes a GH_TOKEN the caller exported
# before invoking this CLI. Phase 1's contract (see cmd_forge_issue_create's
# header) promises that inherited value reaches the child gh process untouched,
# and a bare `GH_TOKEN="$empty"` prefix would silently revoke it. Parameter
# expansion rather than an `if`, so the opt-out is not a second code path: a
# recorded account still wins over the ambient value, since a non-empty override
# never reaches the default arm.
#
# Internals are _faos_-prefixed so the caller's own two locals can never collide
# with the name-reference targets.
_forge_account_override_slots() {
  local -n _faos_gh="$1" _faos_ghe="$2"

  # Warm the host memo HERE, in the caller's own shell. The two lookups below
  # are command substitutions, so a memo either of them populated would die
  # with its subshell -- see _forge_account_host_cached's header.
  local _faos_host=""
  _forge_account_host_cached _faos_host

  _faos_gh=$(_forge_account_override GH_TOKEN)
  _faos_ghe=$(_forge_account_override GH_ENTERPRISE_TOKEN)

  _faos_gh="${_faos_gh:-${GH_TOKEN:-}}"
  _faos_ghe="${_faos_ghe:-${GH_ENTERPRISE_TOKEN:-}}"
}

# ----------------------------------------------------------------------------
# ROUTING RULE FOR THE FOUR FORGE WRITE PATHS (US-006)
# ----------------------------------------------------------------------------
# THE OVERRIDE IS A PREFIX ASSIGNMENT ON EXACTLY ONE COMMAND, ALWAYS. It is
# never `export`ed, never assigned at file scope, and never set by a wrapper
# around a whole function body. That rule is load-bearing rather than
# stylistic: with GH_TOKEN set process-wide, `gh auth status` reports the
# env-token account as "Active account: true", which is precisely the marker
# _forge_auth_status_github parses -- an exported override would make
# forge-auth-status report the OVERRIDDEN account as the machine's active one,
# and would leave the very before/after check that proves the machine account
# was left alone structurally unable to detect a violation.
#
# SEVEN SITES, AND NO OTHERS. Each write function resolves BOTH slots ONCE into
# two locals immediately after its own _forge_bin_check gate -- at most one is
# ever non-empty, and only the matching one costs a `gh auth token` process --
# then names both on every routed command:
#
#   _forge_pr_create              gh pr create      the write
#                                 cmd_forge_pr_view idempotency check
#                                 cmd_forge_pr_view post-create re-read
#   _forge_pr_edit                gh pr edit        the write
#                                 cmd_forge_pr_view post-edit re-read
#   _forge_issue_create           gh issue create   the write
#   _forge_resolve_review_thread  gh api graphql    the resolveReviewThread mutation
#
# Resolved ONCE per invocation, not once per site: a single forge-pr-create run
# reaches gh three or four times and must not re-derive the host and re-mint the
# token each time. That is what _forge_account_override_slots is for -- it fills
# the caller's two locals from a plain statement in the caller's own shell, so
# the host memo it warms survives into the `$(...)` lookups that follow. A memo
# populated INSIDE one of those lookups would die with its subshell, exactly as
# _detect_forge_type's own header spells out.
#
# WHY THE IN-OPERATION READS ARE ROUTED TOO -- correctness, not tidiness: on a
# PRIVATE repository the account that creates a PR can see it while a different
# reader account cannot, so a post-create re-read performed as the machine
# account would fail against a PR that was just successfully created. One
# logical operation stays on one identity. This does NOT make forge-pr-view an
# override-applying verb: invoked directly as its own verb it stays a plain
# machine-account read, and only the reads made INSIDE a write inherit anything.
#
# NO BRANCH FOR THE OPT-OUT. When the remembered answer is "always use whichever
# account is active" -- or nothing was ever recorded -- both locals are empty and
# every site keeps the identical shape, because gh treats an empty token
# variable as unset. An `if` here would be a second code path for the commonest
# case of all.
#
# NOT INVOCATIONS, NOT ROUTED: the two `echo` lines in
# _forge_pr_write_print_manual PRINT a `gh pr create` / `gh pr edit` command for
# a human to run. They shell out to nothing.
#
# ONE CLASSIFIER CALL IS ROUTED, the one inside _forge_resolve_review_thread.
# See the CLASSIFIER SEAM paragraph on _forge_account_override above for why;
# the prefix assignment lives at that call site and
# _forge_classify_gh_failure_reason itself is unmodified.
# ----------------------------------------------------------------------------

# ============================================================================
# forge-auth-status / forge-repo-info (US-003)
# ============================================================================
# Both verbs are read-only forge lookups built directly on detect-forge
# (US-001, called here as a function, never as a `$AIMI_CLI detect-forge`
# subprocess) and the shared PR/issue contract, three-way status envelope,
# and degradation helper above (US-002, commands/references/forge-
# contract.md). Every field name and the found/not_found/error vocabulary
# below comes verbatim from that file -- forge-contract.md is the single
# arbiter, and this section introduces no camelCase unsupportedFields, no
# degradation field the contract does not itself define (the `reason` enum
# below is the contract's own, not a per-verb invention), and no gh
# invocation outside the two private *_github helpers below.
#
# forge-auth-status reports whether the active gh session is authenticated
# AND which account it is acting as -- naming the acting account now is what
# lets phase 2's per-repository account selection extend this verb instead
# of retrofitting it. Phase 1 only compares identity (AIMI_FORGE_IDENTITY
# against whichever account gh already reports active); it does not
# implement switching (no `gh auth switch`, no GH_TOKEN override -- that is
# phase 2's job). Identity is read from an environment variable, NEVER a
# CLI flag -- a value that may later carry a credential must never leak
# through ps or shell history (forge-contract.md "Credential/Identity
# Model").
#
# "Not authenticated" and "could not check at all" are different facts and
# must stay distinguishable, the same discipline roadmap.py's verify_creates_one already
# applies by distinguishing a "missing" identity from a git tool failure
# before ever building a verdict:
#   - gh present, ran, reports no active session for this host -> a
#     CONFIRMED negative. status="found", data.authenticated=false,
#     data.account=null, message=null -- forge-contract.md's "found" covers
#     the lookup succeeding and returning real data, and an authenticated-
#     account check that definitively answers "no" is still a successful
#     lookup, not a broken one.
#   - the forge's own CLI absent from PATH, or the resolved forge has no
#     adapter yet (gitea/unknown -- gitlab gained one in phase 3) -> the
#     check itself could not run. status="error", data=null, message names
#     why, naming the binary THAT forge needs (gh or glab, never a generic
#     placeholder). Callers branch on status/message first, never on
#     data.authenticated alone.
# "not_found" is not used by forge-auth-status: there is no "no such auth
# status" outcome the way there is "no such PR" -- the check either runs to
# a definitive true/false answer (found) or cannot run at all (error).

# Runs `gh auth status` against one host, tolerating a non-zero exit under
# `set -e` (gh's own convention: a non-zero exit here IS the confirmed
# "not authenticated" answer, not a tool failure -- gh auth status has no
# third outcome the way `gh pr view` conflates no-PR with broken auth).
# Combines stdout+stderr since gh's own account listing goes to a different
# stream across versions -- this parser only cares about the text, not
# which stream carried it.
# Prints {authenticated, account, accounts} -- account is the login of
# whichever account gh marks "Active account: true" beneath, or the sole
# account found when gh's output carries no explicit marker line at all.
# `accounts` is EVERY login the same output listed, in gh's own print order,
# de-duplicated, [] when none. It comes out of the SAME single parse pass as
# `account`, deliberately: a second `gh auth status` call or a second parser
# could disagree with this one (gh's output is not guaranteed stable between
# two invocations -- an account can be added, removed or switched between
# them), and a list that disagrees with the active account it is supposed to
# contain is worse than no list at all.
_forge_auth_status_github() {
  local host="$1"
  local out="" rc=0
  if [ -n "$host" ]; then
    out=$(gh auth status --hostname "$host" 2>&1) || rc=$?
  else
    out=$(gh auth status 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    jq -nc '{authenticated: false, account: null, accounts: []}'
    return 0
  fi

  local active="" last="" line seen known
  local accounts=()
  while IFS= read -r line; do
    # Requires whitespace immediately after "account", which is exactly what
    # keeps the marker lines out: "Active account: true" has a colon there,
    # so the marker can never be mistaken for a login.
    if [[ "$line" =~ account[[:space:]]+([^[:space:]]+) ]]; then
      last="${BASH_REMATCH[1]}"
      seen=""
      for known in ${accounts[@]+"${accounts[@]}"}; do
        if [ "$known" = "$last" ]; then
          seen="1"
          break
        fi
      done
      [ -n "$seen" ] || accounts+=("$last")
    fi
    if [[ "$line" == *"Active account: true"* ]]; then
      active="$last"
    fi
  done <<< "$out"
  [ -n "$active" ] || active="$last"

  jq -nc --arg account "$active" --args \
    '{authenticated: true,
      account: (if $account == "" then null else $account end),
      accounts: $ARGS.positional}' ${accounts[@]+"${accounts[@]}"}
}

# The GitLab arm of the same question _forge_auth_status_github answers, and
# emits the IDENTICAL {authenticated, account, accounts} object so
# _forge_auth_status's own envelope builder below is shared rather than
# forked per adapter.
#
# Runs `glab auth status [--hostname <host>]`, combining stdout+stderr for the
# same reason the github helper does -- glab prints its status block through
# its own LogErrorf (stderr), and this parser only cares about the text.
# A NON-ZERO EXIT IS THE CONFIRMED "not authenticated" ANSWER, not a tool
# failure: glab returns an error when no instance is configured at all, and a
# different one when the requested --hostname was never authenticated
# (internal/commands/auth/status/status.go). That is the same convention
# `gh auth status` follows, which is why both helpers can share one shape.
#
# WHY THE PARSE DIFFERS FROM THE GITHUB ONE. glab has no "Active account:
# true" marker line, because it has no multi-account-per-host model to mark:
# its status block prints one `Logged in to <host> as <username> (<source>)`
# line per authenticated INSTANCE. So the login is read out of that line's
# `as <username>` position, and the first one found is the acting account --
# never a marker line, which does not exist here. `--hostname` is always
# passed when a host is known, so at most one instance block is printed;
# `-a`/`--all` is deliberately never passed.
#
# VERIFICATION CEILING (phase-wide): glab is not installed on the machine
# this was written on. The wording above is read off glab's own docs and
# source, not off an observed binary -- the same declared ceiling
# _forge_map_pr_field_gitlab's header states.
_forge_auth_status_gitlab() {
  local host="$1"
  local out="" rc=0
  if [ -n "$host" ]; then
    out=$(glab auth status --hostname "$host" 2>&1) || rc=$?
  else
    out=$(glab auth status 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    jq -nc '{authenticated: false, account: null, accounts: []}'
    return 0
  fi

  local login="" line seen known
  local accounts=()
  while IFS= read -r line; do
    # Anchored on the literal " as " that separates host from login, so a
    # host whose name happens to contain the word "as" cannot be mistaken
    # for the login. The captured run stops at the first whitespace, which
    # is what keeps the trailing "(<source>)" out.
    if [[ "$line" =~ Logged[[:space:]]+in[[:space:]]+to[[:space:]]+[^[:space:]]+[[:space:]]+as[[:space:]]+([^[:space:]]+) ]]; then
      login="${BASH_REMATCH[1]}"
      seen=""
      for known in ${accounts[@]+"${accounts[@]}"}; do
        if [ "$known" = "$login" ]; then
          seen="1"
          break
        fi
      done
      [ -n "$seen" ] || accounts+=("$login")
    fi
  done <<< "$out"

  jq -nc --arg account "${accounts[0]:-}" --args \
    '{authenticated: true,
      account: (if $account == "" then null else $account end),
      accounts: $ARGS.positional}' ${accounts[@]+"${accounts[@]}"}
}

# gitea adapter for forge-auth-status. Same {authenticated, account, accounts}
# contract as its github and gitlab siblings, deliberately kept adjacent so
# the three stay diffable -- and ONE deliberate divergence from the gitlab
# arm, spelled out below because copying that arm by habit is what would
# break this verb.
#
# `tea login list -o json` is an OFFLINE CONFIG READ (cmd/login/list.go,
# modules/print/login.go:34-54): it prints the locally stored login entries
# as an array of all-STRING rows keyed name, url, ssh_host, user, default.
# It never dials the instance. That makes `authenticated: true` here a
# WEAKER claim than gh's validated answer: it proves a login entry for this
# host exists, NOT that its token still works. Recorded so a caller reading
# `authenticated` on a Gitea remote calibrates it correctly rather than
# assuming parity with GitHub's.
#
# WHY NOT `tea whoami`: it makes a network round trip
# (client.Users.GetMyUserInfo, cmd/whoami.go:22-31) and then DISCARDS its own
# error (`user, _, _ :=`) before printing. A probe that throws away the very
# failure it is being asked about cannot answer this question, so no code
# path in this adapter invokes it.
#
# THE ONE DELIBERATE DIVERGENCE FROM _forge_auth_status_gitlab: on a non-zero
# exit, or on stdout jq cannot parse as an array, this returns NON-ZERO
# instead of a clean `{authenticated: false}`. glab's non-zero exit IS its
# confirmed "not authenticated" answer, so folding it into a negative there
# is correct. `tea` exits 1 UNIFORMLY for every error (main.go:18-30 -- there
# is no distinct exit code for anything), so the same reading would
# manufacture a false clean negative out of a broken PATH, a corrupt config
# or a jq-unparseable response. A false negative here is exactly what lets a
# broken session walk into opening a duplicate pull request, which is the
# defect this whole verb exists to prevent. Only an EMPTY match set on a
# cleanly parsed list is a definitive `authenticated: false`.
#
# Entry selection is HOST-FILTERED, never first-wins: `tea login list`
# returns every configured instance, so accepting entry zero would report a
# codeberg.org session as proof of a gitea.com login. The `default` entry
# among the matches wins, else the first match. Comparison is on the URL's
# HOST component (scheme, userinfo, path and port stripped, case-folded), so
# a stored `https://gitea.com/` matches a detected `gitea.com`.
#
# NO CREDENTIAL IS BOUND ANYWHERE IN THIS FUNCTION, and that is a security
# property rather than an omission: `tea` honours GH_TOKEN whenever
# GITEA_INSTANCE_URL is also set (modules/context/context_login.go:15-51), so
# copying the GitHub write path's prefix-assignment habit would hand a GitHub
# token to a Gitea instance. Identity selection on tea is `--login <name>`,
# which names a stored entry and carries no secret; this read verb does not
# need it and does not pass it.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. What the tests prove is WHICH ARGV this function
# emits and HOW it parses a fixture -- never what real `tea` does with them.
# Where that under-verifies is the key NAMES themselves: the stub emits
# whatever the author believed, so a wrong key would pass green on both
# sides. Same declared ceiling _forge_map_pr_field_gitea's header states.
#
# Usage: _forge_auth_status_gitea <host>
#   rc 0 -> {authenticated, account, accounts} on stdout
#   rc 1 -> the check COULD NOT RUN; the caller must report error, never a
#           negative
_forge_auth_status_gitea() {
  local host="${1:-}"
  local out="" rc=0

  # No `--login`, no `-r/--repo`: the login list is instance-wide and this
  # call is the thing that decides WHICH login is active, so scoping it to
  # one would beg the question.
  out=$(tea login list -o json 2>/dev/null) || rc=$?

  if [ "$rc" -ne 0 ]; then
    return 1
  fi

  # A cleanly parsed ARRAY is the precondition for treating an empty match
  # set as a definitive negative. Anything else -- empty stdout, a jq parse
  # error, an object where an array was promised -- proves nothing, so it
  # takes the same could-not-run exit as a non-zero rc above.
  local shape=""
  shape=$(printf '%s' "$out" | jq -r 'type' 2>/dev/null) || shape=""
  if [ "$shape" != "array" ]; then
    return 1
  fi

  jq -nc --arg host "$host" --argjson logins "$out" '
    def hostof:
      ((. // "") | tostring)
      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
      | sub("^[^/@]*@"; "")
      | sub("/.*$"; "")
      | sub(":[0-9]+$"; "")
      | ascii_downcase;
    [ $logins[]
      | select(type == "object")
      | { user: ((.user // "") | tostring),
          host: (.url | hostof),
          isdefault: (((.default // "") | tostring) | ascii_downcase) } ] as $rows
    | (if $host == "" then $rows
       else [ $rows[] | select(.host == ($host | ascii_downcase)) ] end) as $matched
    | ([ $matched[] | select(.isdefault == "true") ] + $matched) as $ordered
    | { authenticated: (($matched | length) > 0),
        account: (((($ordered[0] // {}).user) // "") | if . == "" then null else . end),
        accounts: (reduce ($matched[] | .user | select(. != "")) as $u
                     ([]; if (index($u) != null) then . else . + [$u] end)) }'
}

# Resolves forge/host via detect-forge's own helper (a direct function call,
# never a `$AIMI_CLI detect-forge` subprocess), dispatches to the adapter the
# detected forge needs -- gh for github, glab for gitlab, tea for gitea --
# when that binary is present (checked via the shared _forge_bin_check above
# in its quiet mode: a missing binary here has no caller-mandated stderr
# banner; the caller decides whether a degraded result is fatal), and
# otherwise reports status=error with a message naming why.
# AIMI_FORGE_IDENTITY, when set, is compared only against the already-active
# account -- never used to invoke `gh auth switch` or set GH_TOKEN.
#
# THIS VERB HAS ONLY TWO OUTCOMES, found and error -- the documented
# exception to forge-contract.md's three-way convention. A CONFIRMED "no,
# you are not logged in" is a SUCCESSFUL lookup and reports found with
# data.authenticated=false; error means the check could not run at all. The
# distinction is load-bearing rather than pedantic: a broken check that read
# as a clean negative is what would let a bad session walk into creating a
# duplicate pull request.
_forge_auth_status() {
  local forge_info forge host
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # `// empty` is load-bearing, not decoration: .host is JSON null whenever
  # AIMI_FORGE_TYPE short-circuits detection, and a bare `jq -r '.host'`
  # renders that null as the 4-character TEXT "null". That string is
  # non-empty, so it survives every downstream emptiness check and reaches
  # `gh auth status --hostname null` -- a host gh has no session for, whose
  # refusal then reads as a confirmed authenticated:false. This is the same
  # guard every other nullable field in this file already reads through.
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  local status="error" message="" data_json="null" reason=""

  # ONE binary name, chosen from the detected forge, then ONE shared body.
  # The adapters differ only in which CLI is asked and how its status text is
  # parsed -- both of which are settled before this point -- so the envelope
  # below is built exactly once rather than copied per forge. Only `unknown`
  # leaves this empty and falls through to the no_adapter branch; gitea was
  # routed to `tea` in phase 4 and no longer reaches it.
  local adapter_bin=""
  case "$forge" in
    github) adapter_bin="gh" ;;
    gitlab) adapter_bin="glab" ;;
    gitea)  adapter_bin="tea" ;;
  esac

  if [ -n "$adapter_bin" ]; then
    if _forge_bin_check "$adapter_bin" quiet "$forge"; then
      local cli_out="" cli_rc=0 authenticated_json account identity_requested identity_honored_json
      # ONE adapter selection, THREE arms, still ONE shared envelope builder
      # below -- the jq call is not copied per forge. Only the gitea arm can
      # report "the check could not run at all": `tea` exits 1 UNIFORMLY for
      # every error, so its adapter refuses to turn a failure into a clean
      # negative and signals that refusal as a non-zero return instead. gh's
      # and glab's non-zero exits ARE their own confirmed negatives, so
      # neither can ever reach cli_rc != 0.
      case "$forge" in
        gitlab) cli_out=$(_forge_auth_status_gitlab "$host") ;;
        gitea)  cli_out=$(_forge_auth_status_gitea "$host") || cli_rc=$? ;;
        *)      cli_out=$(_forge_auth_status_github "$host") ;;
      esac

      if [ "$cli_rc" -ne 0 ]; then
        # The adapter could not answer. That is an ERROR, never a negative:
        # emitting authenticated=false here would manufacture a clean
        # negative out of a tool failure, and it is precisely such a false
        # negative that lets a broken session open a duplicate pull request.
        # `data_json` stays null, so `authenticated` cannot be read at all.
        message="$adapter_bin could not report authentication status -- the check did not run"
        reason="cli_failed"
      else
        authenticated_json=$(printf '%s' "$cli_out" | jq -c '.authenticated')
        account=$(printf '%s' "$cli_out" | jq -r '.account // empty')

        identity_requested="${AIMI_FORGE_IDENTITY:-}"
        identity_honored_json="null"
        if [ -n "$identity_requested" ]; then
          if [ "$identity_requested" = "$account" ]; then
            identity_honored_json="true"
          else
            identity_honored_json="false"
          fi
        fi

        status="found"
        # This builder names every field it emits, one by one -- it never
        # splats $cli_out through. That containment is load-bearing, not
        # incidental: _forge_auth_status_github (and its gitlab sibling) also
        # returns an `accounts` array (the whole login list, for the
        # account-divergence section below), and forge-contract.md fixes this
        # envelope's fields. A `+ $cli_out`-style merge here would leak a field
        # the contract does not define into every forge-auth-status caller.
        #
        # `forge` is $forge verbatim, so a GitLab repository reports
        # "gitlab" here -- open-pr.md Step 1a prints `.data.forge` rather than
        # a hardcoded "GitHub", and that is what makes it render correctly.
        data_json=$(jq -nc \
          --arg forge "$forge" \
          --arg host "$host" \
          --argjson authenticated "$authenticated_json" \
          --arg account "$account" \
          --arg identityRequested "$identity_requested" \
          --argjson identityHonored "$identity_honored_json" \
          '{forge: $forge,
            host: (if $host == "" then null else $host end),
            authenticated: $authenticated,
            account: (if $account == "" then null else $account end),
            identityRequested: (if $identityRequested == "" then null else $identityRequested end),
            identityHonored: $identityHonored}')
      fi
    else
      # Names the binary the DETECTED forge actually needs -- `glab` on a
      # GitLab remote, `tea` on a Gitea one, never `gh`. Telling a GitLab
      # user to install gh is the exact "message names the wrong CLI" defect
      # the phase contract's fourth success criterion exists to prevent.
      message="$adapter_bin not found on PATH -- cannot check authentication status"
      reason="cli_missing"
    fi
  else
    message="no forge adapter for ${forge} -- cannot check authentication status"
    reason="no_adapter"
  fi

  # Note which branch does NOT set a reason: the found branch above, which
  # covers the CONFIRMED negative (data.authenticated=false). A definitive
  # "no, you are not logged in" is a successful lookup, so `reason` stays
  # null there despite that outcome's name resembling not_authenticated --
  # `reason` only ever describes a check that could not run at all.
  _forge_emit_status "$status" "$data_json" "$message" "$reason"
}

# Detects whether the session is authenticated with the active forge and
# which account it is acting as. See the section header above for the full
# found/error contract and the AIMI_FORGE_IDENTITY comparison rules. No
# --identity (or similarly named) flag exists anywhere in this parsing loop
# -- identity selection is env-var-only, by design (see section header).
cmd_forge_auth_status() {
  check_jq

  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-auth-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _forge_auth_status
}

# ============================================================================
# Forge account selection -- divergence detection
# ============================================================================
# Answers exactly ONE question: does this repository's git identity disagree
# with the forge account gh is currently acting as, and is there another
# account available to pick instead? Nothing here asks the human, applies an
# account, or remembers an answer -- those are separate concerns owned
# elsewhere. Concretely this section:
#   - reads `git config user.email` / `user.name` and `gh auth status`, and
#     writes NOTHING. No file under ~/.config/aimi/ or .aimi/ is read or
#     created, so this code has no ordering dependency on the account store.
#   - never runs `gh auth switch`, never sets or exports GH_TOKEN, and never
#     calls `gh auth token`. Applying an account is a different job.
#   - makes NO network call. `gh api user --jq .login` would resolve the
#     active login authoritatively but costs a round trip;
#     _forge_auth_status_github already parses it offline, which is why this
#     section extends that parser rather than reaching for the API.
#
# The verdict is a PRIVATE json object consumed in-process by callers in this
# file -- deliberately NOT a fifth forge result envelope. forge-contract.md
# fixes the envelope count at four and its `reason` at a closed four-value
# enum, so:
#   - `basis` is a field on this private verdict, NEVER the `reason` argument
#     of _forge_emit_status. It reuses the contract's own spellings
#     no_adapter / cli_missing / not_authenticated where it means exactly
#     what the contract means by them, and adds diverged /
#     identity_matches_active / single_account / no_git_identity for outcomes
#     that enum does not model. Passing any of those four into
#     _forge_emit_status would be rejected by that function's own case guard,
#     which is the backstop for this rule.
#   - forge-auth-status's emitted envelope is unchanged by this section.
#
# THE HARD PART is that the comparison crosses two namespaces with no general
# mapping: a git identity is an EMAIL, a forge account is a LOGIN. Only
# GitHub's noreply form encodes the login authoritatively; everything else is
# a heuristic, which is why each derived candidate carries its own
# confidence. The heuristics are deliberately biased toward catching the
# AGREEING cases, because the two failure directions are not symmetric: a
# false "they agree" is silent and unrecoverable by the user, while a false
# "they diverge" costs one question that is answered once.

# Prints {email, name} for the identity git would actually stamp on a commit
# in the current working directory -- repository config where set, global
# otherwise, which is why neither read is qualified with --local.
#
# The `|| ` assignment on each read is REQUIRED, not defensive noise: an
# unset key makes `git config --get` exit 1, and a bare `x=$(git config ...)`
# under this file's `set -euo pipefail` would abort the whole CLI on a
# repository that simply has no user.name configured.
_forge_git_identity() {
  local email="" name=""
  email=$(git config --get user.email 2>/dev/null) || email=""
  name=$(git config --get user.name 2>/dev/null) || name=""

  jq -nc --arg email "$email" --arg name "$name" \
    '{email: (if $email == "" then null else $email end),
      name: (if $name == "" then null else $name end)}'
}

# Derives the GitHub logins an email plus a name could plausibly stand for,
# as [{login, confidence}] in decreasing authority, [] when nothing
# login-shaped can be derived at all.
#
# Usage: _forge_identity_logins <email> <name>
#
#   confidence=noreply   The address is GitHub's own noreply form,
#                        [<numeric-id>+]<login>@users.noreply.github.com,
#                        which ENCODES the login exactly. Authoritative, and
#                        emitted alone -- no heuristic can improve on it.
#   confidence=heuristic A guess: the email local-part (with a leading
#                        <digits>+ stripped, the shape GitHub's own noreply
#                        addresses use), and user.name when it is
#                        login-shaped. The shape test ^[A-Za-z0-9][A-Za-z0-9-]*$
#                        is what rejects the overwhelmingly common
#                        "First Last" value of user.name.
#
# The noreply DOMAIN is compared case-insensitively (mail domains are), but
# only a lowercased COPY of the domain is used for that test so the login the
# local-part carries keeps the casing its owner typed. Callers compare
# case-insensitively anyway, since GitHub logins are.
_forge_identity_logins() {
  local email="$1" name="$2"
  local entries=() local_part domain login

  local_part="${email%@*}"
  domain=$(printf '%s' "${email##*@}" | tr '[:upper:]' '[:lower:]')

  if [ "$domain" = "users.noreply.github.com" ] &&
     [[ "$local_part" =~ ^([0-9]+\+)?([A-Za-z0-9][A-Za-z0-9-]*)$ ]]; then
    login="${BASH_REMATCH[2]}"
    jq -nc --arg login "$login" '[{login: $login, confidence: "noreply"}]'
    return 0
  fi

  local candidate
  candidate="${email%%@*}"
  if [[ "$candidate" =~ ^[0-9]+\+(.*)$ ]]; then
    candidate="${BASH_REMATCH[1]}"
  fi
  if [[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    entries+=("$(jq -nc --arg login "$candidate" '{login: $login, confidence: "heuristic"}')")
  fi

  if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] &&
     [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')" ]; then
    entries+=("$(jq -nc --arg login "$name" '{login: $login, confidence: "heuristic"}')")
  fi

  if [ ${#entries[@]} -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${entries[@]}" | jq -sc '.'
}

# Prints exactly one verdict object:
#   {decision, basis, forge, host, activeAccount, accounts, identity, match}
#     decision       "ask" | "skip" -- whether the caller should raise the
#                    account question at all. Necessary, not sufficient: a
#                    caller that has already recorded an answer for this
#                    repository combines that with this verdict.
#     basis          why (see the section header -- NOT the contract's reason)
#     forge          the resolved forge, from _detect_forge
#     host           the resolved host, or null
#     activeAccount  the login gh is currently acting as, or null
#     accounts       every login gh reports, in gh's own order, [] when none
#     identity       {email, name} this repository's git identity
#     match          "noreply" | "heuristic" | "none" -- the confidence of
#                    the derived login that MATCHED activeAccount, "none"
#                    when none did or the comparison never ran
#
# The decision table below is evaluated in a fixed order, each rung mutually
# exclusive with the ones above it. Two orderings are deliberate:
#   - identity_matches_active is checked BEFORE single_account, so a
#     one-account repository whose identity genuinely agrees reports the
#     informative basis rather than the incidental one.
#   - single_account SKIPS rather than asks. With one account logged in there
#     is no alternative to offer: account selection resolves logins already
#     in gh's keyring, so a one-account machine has no remedy even when the
#     identity plainly disagrees. Recording the basis is what lets a caller
#     say why it stayed quiet instead of appearing to have no opinion.
_forge_account_divergence() {
  local forge_info forge host
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # `// empty` is load-bearing here for exactly the reason spelled out at
  # _forge_auth_status's own host read above (aimi-cli.sh:2757-2763): .host
  # is JSON null whenever AIMI_FORGE_TYPE short-circuits detection, and a
  # bare `jq -r '.host'` renders that null as the 4-character TEXT "null" --
  # non-empty, so it survives every downstream emptiness check and reaches
  # `gh auth status --hostname null`, whose refusal then reads as a CONFIRMED
  # not-authenticated answer. This read is the only way a host reaches gh
  # from this function, so "" is the only value that can stand for "no host".
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  local identity_json email name
  identity_json=$(_forge_git_identity)
  email=$(printf '%s' "$identity_json" | jq -r '.email // empty')
  name=$(printf '%s' "$identity_json" | jq -r '.name // empty')

  local decision="skip" basis="" active="" accounts_json="[]" match="none"

  if [ "$forge" != "github" ]; then
    basis="no_adapter"
  elif ! _forge_bin_check gh quiet github; then
    basis="cli_missing"
  else
    local gh_out authenticated
    gh_out=$(_forge_auth_status_github "$host")
    authenticated=$(printf '%s' "$gh_out" | jq -r '.authenticated')
    active=$(printf '%s' "$gh_out" | jq -r '.account // empty')
    accounts_json=$(printf '%s' "$gh_out" | jq -c '.accounts')

    if [ "$authenticated" != "true" ]; then
      basis="not_authenticated"
    elif [ -z "$email" ] && [ -z "$name" ]; then
      basis="no_git_identity"
    else
      local logins_json matched
      logins_json=$(_forge_identity_logins "$email" "$name")
      # First candidate that matches wins, and _forge_identity_logins emits
      # the authoritative noreply candidate alone -- so `match` reports the
      # strongest confidence that actually agreed, never a weaker one that
      # happened to be listed first.
      matched=$(printf '%s' "$logins_json" | jq -r --arg active "$active" \
        '($active | ascii_downcase) as $a
         | if $a == "" then empty
           else (map(select((.login | ascii_downcase) == $a)) | .[0] // null
                 | if . == null then empty else .confidence end)
           end')

      if [ -n "$matched" ]; then
        basis="identity_matches_active"
        match="$matched"
      elif [ "$(printf '%s' "$accounts_json" | jq 'length')" -lt 2 ]; then
        basis="single_account"
      else
        decision="ask"
        basis="diverged"
      fi
    fi
  fi

  jq -nc \
    --arg decision "$decision" \
    --arg basis "$basis" \
    --arg forge "$forge" \
    --arg host "$host" \
    --arg activeAccount "$active" \
    --argjson accounts "$accounts_json" \
    --arg email "$email" \
    --arg name "$name" \
    --arg match "$match" \
    '{decision: $decision,
      basis: $basis,
      forge: $forge,
      host: (if $host == "" then null else $host end),
      activeAccount: (if $activeAccount == "" then null else $activeAccount end),
      accounts: $accounts,
      identity: {email: (if $email == "" then null else $email end),
                 name: (if $name == "" then null else $name end)},
      match: $match}'
}

# ============================================================================
# Forge account selection -- the remembered answer
# ============================================================================
# Owns THREE operations on ONE document: record an answer, read it back and
# decide, and revoke it. It does not ask the human. That split is settled repo
# convention, not a choice made here: commands/references/interactivity.md puts
# the question in the COMMAND layer, and the reason is mechanical -- the only
# interactive prompt in this entire file, _prompt_category, is gated on
# `[ -t 0 ]` and reads /dev/tty, which never fires under Claude Code because
# the CLI is invoked through the Bash tool with a non-TTY stdin. A prompt
# implemented here would be silently dead in the only host that matters.
#
# THREE SHIPPED BUGS FROM THIS REPOSITORY'S OWN MODELS FLOW LAND HERE. None is
# hypothetical; each cost a release:
#
#   1. AN ANSWER THAT COULD NOT BE REVOKED (1.93.0, CHANGELOG:615). The models
#      dismissal marker "suppressed the prompt even after the config was
#      deleted, leaving the user silently stuck on all-inherit defaults with no
#      way to re-trigger the prompt short of also deleting the marker." The fix
#      decoupled the two files so deleting the ANSWER always re-triggers. That
#      is why --reselect exists in this verb at all, and why there is no
#      companion marker or sentinel anywhere in this section: THE ANSWER IS THE
#      ONLY STATE. Deleting the store by hand does exactly what --reselect does.
#
#   2. CHECKED BY FILE EXISTENCE RATHER THAN CONTENT (1.93.1, CHANGELOG:604).
#      `models-prompt-check` returned `skip` whenever models.json existed, even
#      when the current host's sub-table was missing or empty. The analogue here
#      is worse than an inconvenience: the store file exists the moment THIS
#      repository first answers, and phases 3/4 add gitlab.com and gitea hosts
#      to the same document, so a check that reads "file exists -> don't ask"
#      would silence every host after the first. --check therefore decides on
#      THIS HOST'S ENTRY, and an absent / empty / malformed store and an entry
#      that does not encode a usable answer ALL yield ask, never a silent skip.
#
#   3. A WRITER THAT CLOBBERED A SIBLING SCOPE (1.97.2, CHANGELOG:487).
#      `detect-models` in default mode "wrote a fresh document via `jq -n`,
#      silently dropping the inactive host's configured models on every
#      invocation." Every write here is read-merge-write through the single
#      _forge_account_store_merge path below, and NO code path in this section
#      reconstructs the document with `jq -n`. --reselect is the trap: writing
#      the file back without the entry is the obvious implementation and it
#      destroys every other host's answer, so it too is a merge (`del`), not a
#      rebuild. _forge_account_store_path's own header states the same
#      obligation from the store's side.
#
# DOCUMENT SHAPE, and why a REBUILD is impossible rather than merely discouraged:
# the store is a JSON object keyed by forge host, one file per repository
# (_forge_account_store_path). This function CANNOT enumerate the hosts a
# repository will ever use -- it only ever learns the ONE host _detect_forge
# resolves from the remote it is standing in front of right now. A rebuild
# would have to invent the other hosts' entries out of nothing, so read-merge-
# write is the only implementation that can be correct, not a stylistic
# preference. Each entry is:
#     {"mode": "active",  "recordedAt": "<ISO 8601 UTC>"}
#     {"mode": "account", "account": "<login>", "recordedAt": "<ISO 8601 UTC>"}
# The `mode` discriminator is what makes "the user chose to always use whichever
# account is active" a FIRST-CLASS persisted answer, distinguishable from "the
# user has not been asked". Encoding the opt-out as an empty account string, or
# by omitting the entry, is rejected on both the write and the read side --
# neither is distinguishable from absent, which is precisely the property the
# opt-out must not have.

# Reads the store document, normalizing every degenerate input to `{}`:
# file absent, file empty, file unreadable, file holding malformed JSON, and
# file holding valid JSON that is not an object (an array or a bare string a
# hand-edit could leave behind). Prints exactly one JSON object on stdout.
#
# Normalizing rather than erroring is bug 2's lesson applied at the read: the
# caller's next step compares THIS HOST'S entry against `{}` and asks when it
# finds nothing, so a corrupt store degrades into "nobody has answered yet"
# and the user gets the question back. The alternative -- treating malformed
# as "already answered" -- is the silent skip that shipped.
_forge_account_store_read() {
  local store="${1:-}" raw=""

  if [ -z "$store" ] || [ ! -f "$store" ]; then
    printf '{}\n'
    return 0
  fi

  raw=$(cat "$store" 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then
    printf '{}\n'
    return 0
  fi

  printf '%s' "$raw" | jq -c 'if type == "object" then . else {} end' 2>/dev/null || printf '{}\n'
}

# THE ONLY WRITE PATH IN THIS SECTION. Read-merge-write, under one lock.
# Usage: _forge_account_store_merge <store_path> <jq_filter> <jq_arg>...
#
# The jq filter is applied to the CURRENT document, read INSIDE the lock, so a
# concurrent writer cannot slip between the read and the write and lose an
# entry -- which is the whole reason the read is not hoisted out to the caller
# where it would be easier to see.
#
# Combines the two precedents this repository already has rather than inventing
# a third: roadmap-init's `( _lock "$f.lock"; ...; mv ) 200>"$f.lock"` subshell
# shape, and write_aimi_models_config's create-then-restrict-then-write
# ordering (mkdir -p, mktemp, chmod 0600 BEFORE any content, mv, temp removed on
# mv failure). The 0600-before-content ordering is load-bearing for a file that
# names accounts: it must never exist, even for the instant between creation and
# the first write, readable by anyone but its owner.
#
# read_state/write_state are deliberately NOT used: their flock +
# validate_path_in_project discipline is scoped to AIMI_ROOT/.aimi/ and does not
# transfer to a path under the aimi config directory.
#
# The `|| rc=$?` makes the subshell the left side of an AND-OR list, the one
# construct `set -e` is defined to exempt, so a lock path that cannot be opened
# is a reportable failure rather than an instant, silent exit. The `200>`
# redirect stays attached to the subshell, before the `||`.
_forge_account_store_merge() {
  local store="$1" filter="$2"
  shift 2

  local dir
  dir=$(dirname "$store")
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "Error: forge-account-select: cannot create directory: $dir" >&2
    return 1
  fi

  local tmp=""
  tmp=$(mktemp "${store}.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$tmp" ]; then
    echo "Error: forge-account-select: cannot create a temp file beside $store" >&2
    return 1
  fi
  chmod 0600 "$tmp"

  local rc=0
  (
    _lock "${store}.lock"
    local current merged
    current=$(_forge_account_store_read "$store")
    merged=$(printf '%s' "$current" | jq -c "$@" "$filter") || exit 1
    printf '%s\n' "$merged" > "$tmp"
    mv "$tmp" "$store"
  ) 200>"${store}.lock" || rc=$?

  rm -f "$tmp" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    echo "Error: forge-account-select: failed to write $store" >&2
    return 1
  fi
}

# Prints the forge host this repository's answer is keyed under, or nothing.
#
# `// empty` is not defensive noise. .host is JSON null whenever AIMI_FORGE_TYPE
# short-circuits _detect_forge, and a bare `jq -r '.host'` renders that null as
# the 4-character TEXT "null" -- non-empty, so it survives every downstream
# emptiness check. Commit d1b19ca is where that exact value reached
# `gh auth status --hostname null` and its refusal read as a CONFIRMED
# not-authenticated answer. Here it would key an entry under the literal host
# "null", which no later invocation resolving a real host would ever find again.
_forge_account_host() {
  local forge_info
  forge_info=$(_detect_forge)
  printf '%s' "$forge_info" | jq -r '.host // empty'
}

# Extracts THIS host's recorded answer from a store document, or `null`.
#
# The mode discriminator is validated here, not merely read: an entry that is
# not an object, carries an unrecognized mode, or encodes mode "account" with a
# missing or empty account is reported as `null` -- i.e. "nobody has answered".
# That is bug 2's content-check discipline pushed one level down from the
# document to the entry, and it is also the read-side half of rejecting the
# empty string as an encoding of the "always use the active account" opt-out.
_forge_account_stored_entry() {
  local store="$1" host="$2"

  if [ -z "$store" ] || [ -z "$host" ]; then
    printf 'null\n'
    return 0
  fi

  _forge_account_store_read "$store" | jq -c --arg host "$host" '
    (.[$host] // null) as $e
    | if ($e | type) != "object" then null
      elif $e.mode == "active" then $e
      elif $e.mode == "account" and ($e.account | type) == "string" and $e.account != "" then $e
      else null
      end'
}

# Usage/mode error. Always exits 1 -- every caller relies on that, so no arm of
# the parsing loop needs its own guard against falling through.
_forge_account_select_usage() {
  if [ -n "${1:-}" ]; then
    echo "Error: forge-account-select: $1" >&2
  fi
  echo "Usage: aimi-cli.sh forge-account-select (--check | --record <login> | --record-active | --reselect) [--project <path>]" >&2
  echo "  Exactly one mode is required:" >&2
  echo "    --check           read this repository's recorded answer back and decide whether the account question is warranted; writes nothing" >&2
  echo "    --record <login>  remember <login> as this repository's forge account" >&2
  echo "    --record-active   remember \"always use whichever account is active\" -- a real answer, not the absence of one" >&2
  echo "    --reselect        forget this repository's answer so the next --check asks again" >&2
  exit 1
}

# --check. Reads and decides; writes NOTHING -- no store file, no config
# directory, no chmod, no mutation of a pre-existing store.
#
# That is not tidiness, it is the mechanical guarantee behind the agent-mode
# rule. interactivity.md requires every question site to auto-select under
# AIMI_AGENT_MODE / CI / --non-interactive, and if that auto-answer were
# persisted, ONE CI run would silently and permanently answer the question for
# every human who touched the repository afterwards. Applied-but-not-persisted
# is enforced by --check writing nothing at all; persisting is always a
# separate, explicit --record* call the command layer makes only after a human
# actually answered.
#
# The rungs below are mutually exclusive and evaluated in a fixed order:
#   identity_override  AIMI_FORGE_IDENTITY names the account to act as, so the
#                      question is moot. Highest precedence, matching this
#                      file's own env-over-stored convention (AIMI_FORGE_TYPE
#                      short-circuits detection entirely).
#   no_repository      no resolvable git identity, so there is nowhere to
#                      remember an answer. Near-unreachable behind
#                      _require_git_repo; kept because _forge_account_store_path
#                      is documented to be allowed to decline.
#   no_host            no forge host resolved (no remote, or AIMI_FORGE_TYPE
#                      overriding detection), so the answer has no key. Asking
#                      a question whose answer cannot be stored is worse than
#                      not asking.
#   answer_recorded    this host already has a usable answer.
#   <divergence basis> otherwise the verdict from _forge_account_divergence is
#                      adopted verbatim, decision and basis together. That
#                      verdict is necessary but not sufficient on its own,
#                      which is exactly what the rungs above supply.
_forge_account_select_check() {
  local store="$1"
  local verdict host stored decision basis

  verdict=$(_forge_account_divergence)
  host=$(printf '%s' "$verdict" | jq -r '.host // empty')
  stored=$(_forge_account_stored_entry "$store" "$host")

  decision="skip"
  if [ -n "${AIMI_FORGE_IDENTITY:-}" ]; then
    basis="identity_override"
  elif [ -z "$store" ]; then
    basis="no_repository"
  elif [ -z "$host" ]; then
    basis="no_host"
  elif [ "$stored" != "null" ]; then
    basis="answer_recorded"
  else
    decision=$(printf '%s' "$verdict" | jq -r '.decision')
    basis=$(printf '%s' "$verdict" | jq -r '.basis')
  fi

  printf '%s' "$verdict" | jq -c \
    --arg decision "$decision" \
    --arg basis "$basis" \
    --argjson stored "$stored" \
    --arg store "$store" \
    '{action: "check"}
     + .
     + {decision: $decision,
        basis: $basis,
        stored: $stored,
        store: (if $store == "" then null else $store end)}'
}

# --record <login> and --record-active. Both persist through the one merge path.
_forge_account_select_record() {
  local store="$1" entry_mode="$2" login="$3"

  if [ -z "$store" ]; then
    echo "Error: forge-account-select: no resolvable git repository here, so there is nowhere to record an answer" >&2
    exit 1
  fi

  local host
  host=$(_forge_account_host)
  if [ -z "$host" ]; then
    echo "Error: forge-account-select: no forge host resolved for this repository -- an answer is keyed by host, so there is nothing to key it under" >&2
    echo "  A host comes from the git remote; AIMI_FORGE_TYPE overrides forge detection and deliberately reports no host." >&2
    exit 1
  fi

  local recorded_at entry
  recorded_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  if [ "$entry_mode" = "active" ]; then
    entry=$(jq -nc --arg at "$recorded_at" '{mode: "active", recordedAt: $at}')
  else
    entry=$(jq -nc --arg account "$login" --arg at "$recorded_at" \
      '{mode: "account", account: $account, recordedAt: $at}')
  fi

  # `.[$host] = $entry` -- assignment into the document that was just read, so
  # every OTHER host's entry survives byte-for-byte. Never `jq -n`.
  _forge_account_store_merge "$store" '.[$host] = $entry' \
    --arg host "$host" --argjson entry "$entry" || exit 1

  jq -nc --arg host "$host" --arg store "$store" --argjson stored "$entry" \
    '{action: "record", host: $host, store: $store, stored: $stored}'
}

# --reselect. Revocation, and the ONLY state involved: there is no companion
# marker to also delete, so this and `rm` on the store file are equivalent.
_forge_account_select_reselect() {
  local store="$1"

  if [ -z "$store" ]; then
    echo "Error: forge-account-select: no resolvable git repository here, so there is no answer to forget" >&2
    exit 1
  fi

  local host
  host=$(_forge_account_host)
  if [ -z "$host" ]; then
    echo "Error: forge-account-select: no forge host resolved for this repository -- an answer is keyed by host, so there is nothing to look up" >&2
    exit 1
  fi

  local had
  had=$(_forge_account_stored_entry "$store" "$host")

  # `del(.[$host])` on the document that was just read. Rewriting the file
  # without the entry is the obvious implementation and it is CHANGELOG:487
  # exactly: every other host's answer would go with it.
  _forge_account_store_merge "$store" 'del(.[$host])' --arg host "$host" || exit 1

  local cleared="false"
  if [ "$had" != "null" ]; then
    cleared="true"
  fi

  jq -nc --arg host "$host" --arg store "$store" --argjson cleared "$cleared" \
    '{action: "reselect", host: $host, store: $store, stored: null, cleared: $cleared}'
}

# Records, reads back and revokes this repository's forge account answer.
#
# Usage: aimi-cli.sh forge-account-select (--check | --record <login> |
#                                          --record-active | --reselect)
#                                         [--project <path>]
#
# RESELECT IS A FLAG, NEVER A SECOND VERB. The phase declares exactly one
# `creates` identity for this work, cmd_forge_account_select, and verify-creates
# greps tracked source for that literal string at phase close; a second verb
# would need a second identity and a roadmap amendment. Revocation was
# originally proposed as its own story and was folded in here precisely to keep
# that contract intact.
#
# NO --token, --identity OR OTHERWISE CREDENTIAL-SHAPED FLAG EXISTS in the
# parsing loop below, and none may be added. cmd_forge_pr_create,
# cmd_forge_pr_edit and cmd_forge_issue_create each carry the same statement:
# an identity reaches a forge CLI only through the environment, never through
# argv, because argv leaks through `ps` and shell history. A LOGIN is not a
# credential, which is why --record takes one -- but the flag namespace stays
# clear of anything a future reader could mistake for a token sink.
cmd_forge_account_select() {
  check_jq

  local mode="" account="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --check)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --check) -- exactly one is allowed"
        fi
        mode="check"
        ;;
      --record)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --record) -- exactly one is allowed"
        fi
        mode="record"
        # Consumes the value only when one is actually there. A bare `shift`
        # on the last argument returns non-zero, and this file runs `set -e`,
        # so `--record` with no login would abort the process before the
        # empty-value check below could print anything at all.
        if [ $# -ge 2 ]; then
          shift
          account="$1"
        fi
        ;;
      --record-active)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --record-active) -- exactly one is allowed"
        fi
        mode="record-active"
        ;;
      --reselect)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --reselect) -- exactly one is allowed"
        fi
        mode="reselect"
        ;;
      --project)
        if [ $# -ge 2 ]; then
          shift
          project_dir="$1"
        fi
        ;;
      *)
        _forge_account_select_usage "unknown flag: $1"
        ;;
    esac
    shift
  done

  if [ -z "$mode" ]; then
    _forge_account_select_usage "no mode given"
  fi

  # An empty --record value is refused rather than stored. Storing "" would
  # encode the "always use the active account" opt-out as a value that is
  # indistinguishable from absent -- the one property that answer must not
  # have. A leading dash is refused too: it is a flag the parser swallowed as
  # a value, never a login anyone meant to type.
  if [ "$mode" = "record" ]; then
    if [ -z "$account" ]; then
      _forge_account_select_usage "--record requires a <login>; --record-active is the way to say \"always use whichever account is active\""
    fi
    case "$account" in
      -*)
        _forge_account_select_usage "--record got \"$account\", which looks like a flag rather than a login"
        ;;
    esac
  fi

  _require_git_repo "$project_dir"

  local store=""
  store=$(_forge_account_store_path) || store=""

  case "$mode" in
    check)         _forge_account_select_check "$store" ;;
    record)        _forge_account_select_record "$store" "account" "$account" ;;
    record-active) _forge_account_select_record "$store" "active" "" ;;
    reselect)      _forge_account_select_reselect "$store" ;;
  esac
}

# Requests owner and name from a single `gh repo view` call -- never the two
# separate calls skills/resolve-pr-parallel/scripts/get-pr-comments makes
# today. Prints {owner, repo} on success; returns 1 (no output) on any
# failure so the caller falls back without needing to know why gh failed
# (missing auth, network, or anything else -- mirrors _resolve_default_
# branch's own primary-call-plus-offline-fallback shape, which does not
# distinguish why the primary failed either).
_forge_repo_info_github() {
  local raw="" rc=0
  raw=$(gh repo view --json owner,name 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  printf '%s' "$raw" | jq -c '{owner: .owner.login, repo: .name}' 2>/dev/null || return 1
}

# The GitLab arm of _forge_repo_info_github: one `glab repo view -F json`
# call, printing {owner, repo} on success and returning 1 (no output) on any
# failure so the caller falls through to the same local-parse tier -- exactly
# the contract the github helper above already has.
#
# `-F json`, NOT a gh-style `--json <field-list>`. glab has no field selector
# on any read command: `-F, --output string  Format output as: text, json`
# plus `--jq string  Filter JSON output with a jq expression` is the whole
# interface (docs/source/repo/view.md), so the call asks for the WHOLE
# document and this function picks keys out of it afterwards.
#
# GitLab models ownership as a NAMESPACE PATH, not an owner login, and that
# path can be arbitrarily deep (group/subgroup/subgroup/project). So the
# split is done by the SAME _forge_repo_info_parse_url the local-parse tier
# uses -- it already treats every segment before the last as the owner,
# specifically so a nested subgroup survives intact (see its header). Feeding
# it a bare `group/subgroup/project` path exercises its no-scheme, no-colon
# branch, which is a plain "last segment is the repo" split.
#
# `path_with_namespace` is the primary key; `namespace.full_path` + `path` is
# the equivalent recomposition, kept as a fallback for a response that omits
# the flattened form. Both are go-gitlab *gitlab.Project struct tags
# (`PathWithNamespace json:"path_with_namespace"`, `Path json:"path"`,
# `Namespace json:"namespace"` -> `FullPath json:"full_path"`), which ARE
# glab's JSON keys because glab marshals the struct rather than projecting
# it -- the same evidence chain, and the same declared verification ceiling
# (glab not installed here), that _forge_map_pr_field_gitlab's header states.
_forge_repo_info_gitlab() {
  local raw="" rc=0
  raw=$(glab repo view -F json 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi

  local path=""
  path=$(printf '%s' "$raw" | jq -r '
    if (.path_with_namespace // "") != "" then .path_with_namespace
    elif (.namespace.full_path // "") != "" and (.path // "") != "" then (.namespace.full_path + "/" + .path)
    else "" end' 2>/dev/null) || return 1

  [ -n "$path" ] || return 1

  _forge_repo_info_parse_url "$path"
}

# Parses owner/repo directly out of a git remote URL -- the offline fallback
# used when gh is absent, unauthenticated, or the forge has no adapter yet.
# Every path segment before the last becomes owner (not just the
# second-to-last), so a GitLab-style nested subgroup path
# (group/subgroup/repo) survives intact for the GitLab adapter phase 3 later
# shipped. Prints {owner, repo}, both null when the path never yields at
# least two segments.
_forge_repo_info_parse_url() {
  local url="$1" path=""

  if [[ "$url" == *"://"* ]]; then
    path="${url#*://}"
    path="${path#*/}"
  elif [[ "$url" == *":"* ]]; then
    path="${url#*:}"
  else
    path="$url"
  fi

  path="${path%.git}"
  path="${path#/}"
  path="${path%/}"

  local repo="" owner=""
  if [ -n "$path" ] && [[ "$path" == */* ]]; then
    repo="${path##*/}"
    owner="${path%/*}"
  fi

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    jq -nc '{owner: null, repo: null}'
    return 0
  fi

  jq -nc --arg owner "$owner" --arg repo "$repo" '{owner: $owner, repo: $repo}'
}

# Two-tier resolution mirroring _resolve_default_branch's own shape: a forge
# adapter is the primary path when the detected forge has one AND its CLI is
# present (github -> gh, gitlab -> glab); parsing owner/repo straight out of
# the already-resolved remote URL is the offline fallback, used whenever that
# CLI is missing, unauthenticated, the forge has no adapter, or the primary
# call otherwise fails. AT MOST ONE forge CLI is ever invoked -- the arms are
# an if/elif chain keyed on the detected forge, so a GitLab repository never
# shells out to gh and a GitHub one never shells out to glab. When even
# the fallback yields no usable owner/repo (no origin configured, or a path
# that never splits into two segments), reports status=not_found -- a
# confirmed absence, not a tool error, per forge-contract.md's Three-Way
# Status Convention.
_forge_repo_info() {
  local forge_info forge host remote_url
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # See _forge_auth_status's note on the same read: a JSON null host must
  # become the empty string, never the text "null". Downstream, this is what
  # makes _forge_pr_write_print_manual's own already-correct
  # `.data.host // empty` fallback fire at all -- the string "null" is truthy
  # in jq, so that fallback was silently dead and printed https://null/... .
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')
  remote_url=$(printf '%s' "$forge_info" | jq -r '.remoteUrl // empty')

  local owner="" repo="" source=""

  # THERE IS NO gitea TIER IN THIS CHAIN, AND ITS ABSENCE IS A DECISION.
  # Recorded here rather than left as a gap, so the next reader meets a
  # reason instead of an oversight:
  #   - `tea` has no "show the current repository as JSON" command at all.
  #   - `tea repos <owner>/<name>` REQUIRES the slug as an argument -- the
  #     very thing a repo-info tier would have to local-parse out of the
  #     remote URL first -- and then calls print.RepoDetails WITHOUT
  #     honouring `--output` (cmd/repos.go:47-65), so there is no JSON to
  #     read back either.
  #   - `tea repos list` lists every accessible repository, not this one.
  # A gitea arm would therefore local-parse the answer, ask tea about it, and
  # learn nothing -- pure cost. gitea falls through to _forge_repo_info_parse_url
  # below and reports source "local-parse", which is a correct answer and the
  # reason this verb already worked for Gitea before any adapter existed.
  # (Read off gitea/tea `main` source on 2026-08-06; `tea` is not installed
  # on the machine this was written on.)
  if [ "$forge" = "github" ] && _forge_bin_check gh quiet github; then
    local gh_json=""
    if gh_json=$(_forge_repo_info_github); then
      owner=$(printf '%s' "$gh_json" | jq -r '.owner // empty')
      repo=$(printf '%s' "$gh_json" | jq -r '.repo // empty')
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        source="gh"
      fi
    fi
  elif [ "$forge" = "gitlab" ] && _forge_bin_check glab quiet gitlab; then
    # `source` distinguishes WHICH tier answered, so a GitLab repository
    # whose glab call succeeded reports "glab" and is no longer indistinguish-
    # able from one that only ever managed the offline remote-URL parse.
    local glab_json=""
    if glab_json=$(_forge_repo_info_gitlab); then
      owner=$(printf '%s' "$glab_json" | jq -r '.owner // empty')
      repo=$(printf '%s' "$glab_json" | jq -r '.repo // empty')
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        source="glab"
      fi
    fi
  fi

  if { [ -z "$owner" ] || [ -z "$repo" ]; } && [ -n "$remote_url" ]; then
    local parsed
    parsed=$(_forge_repo_info_parse_url "$remote_url")
    owner=$(printf '%s' "$parsed" | jq -r '.owner // empty')
    repo=$(printf '%s' "$parsed" | jq -r '.repo // empty')
    if [ -n "$owner" ] && [ -n "$repo" ]; then
      source="local-parse"
    fi
  fi

  local status="not_found" data_json="null"
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    status="found"
    data_json=$(jq -nc \
      --arg forge "$forge" \
      --arg host "$host" \
      --arg owner "$owner" \
      --arg repo "$repo" \
      --arg source "$source" \
      '{forge: $forge,
        host: (if $host == "" then null else $host end),
        owner: $owner,
        repo: $repo,
        nameWithOwner: ($owner + "/" + $repo),
        source: $source}')
  fi

  _forge_emit_status "$status" "$data_json" ""
}

# Resolves the active forge's owner/repo for the current git repository. See
# the section header above for the gh-primary/local-parse-fallback contract.
cmd_forge_repo_info() {
  check_jq

  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-repo-info: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _forge_repo_info
}

# ============================================================================
# forge-pr-view (US-004)
# ============================================================================
# Fixes the exact defect commands/open-pr.md carries today:
#   gh pr view "$CURRENT_BRANCH" --json url --jq '.url' 2>/dev/null
# exits non-zero for BOTH "no PR exists for this branch" AND "gh/auth is
# broken" -- a broken token reads as "no PR yet" and open-pr.md proceeds to
# create a duplicate. forge-pr-view adopts the three-way found/not_found/
# error status forge-contract.md publishes so a caller can finally tell the
# two apart, and adds a --include field selector so a caller that only wants
# `url` (open-pr.md's own two call sites) never pays for the expensive
# `files` field the way every current `gh pr view --json` call site does
# today regardless of what it actually asked for.
#
# This verb's envelope is deliberately its OWN shape --
# {status, pr, unsupported_fields, message} -- rather than the generic
# three-way envelope _forge_emit_status builds ({status, data, message,
# reason}): the --include selector requires `pr` to carry exactly the caller's
# requested keys and no others, never the full fixed superset
# _forge_build_pr_json always returns, and a not_found outcome here must
# carry a populated `message` (naming the ref that was searched) rather
# than staying forced-null the way _forge_emit_status's own `message` does
# for every outcome but error -- which forge-contract.md's Three-Way Status
# Convention explicitly permits for not_found ("message is null unless a
# short human-readable note is useful"). The found/not_found/error status
# vocabulary still matches that convention exactly, and the degraded-reason
# field is named `message` here for the same reason: it is the contract's
# own human-readable degradation signal, never a per-verb invention. This
# envelope deliberately does NOT carry the machine-readable `reason` enum
# the shared builder now emits -- forge-contract.md's Degradation Reason
# Enum names forge-pr-view's shape as the one exception `reason` is not
# extended onto.
#
# Field names inside `pr` are the NORMALIZED PR contract's own (number,
# url, title, body, state, headRefName, baseRefName, files, isDraft,
# mergeable) -- never gh's raw vocabulary. gh's response is translated in
# both directions by _forge_map_pr_field_github and normalized through the
# one shared _forge_build_pr_json builder, so GitHub's raw shape never
# leaks past this adapter. On github the two vocabularies happen to be
# identical today, so every current call site's own jq expression (e.g.
# `.files[].path`) survives unchanged.
#
# Phase 3 added the gitlab adapter alongside it (_forge_pr_view_gitlab,
# `glab mr view <ref> -F json`). gitea still has none, and it -- plus a
# missing gh OR a missing glab -- degrades through the quiet
# _forge_bin_check mode, matching review.md's own already-documented git-diff
# fallback for a missing gh so a migration onto this verb introduces no new
# warning banner.

# Emit the forge-pr-view envelope: {status, pr, unsupported_fields, message}.
# status must be found | not_found | error (anything else is a caller error,
# exit 1 -- never silently coerced). pr and unsupported_fields are forced
# null unless status=="found"; message is forced null only when
# status=="found" -- not_found and error both carry a populated message
# string (the searched ref, or gh's own failure text, respectively).
#
# On found, unsupported_fields is ALWAYS a JSON array, never a bare null --
# including an explicitly empty [] when every requested capability-gated
# field was supplied. A bare null there would be a third state alongside
# "empty" and "populated" that no caller can interpret; the array-or-null
# split is driven purely by status, mirroring _forge_emit_status's own
# null-forcing convention.
_forge_pr_view_emit() {
  local status="$1" pr_json="${2:-null}" unsupported_json="${3:-null}" message="${4:-}"

  case "$status" in
    found|not_found|error) ;;
    *)
      echo "Error: _forge_pr_view_emit: status must be found, not_found or error (got: $status)" >&2
      return 1
      ;;
  esac

  if [ "$status" = "found" ]; then
    message=""
    if [ -z "$unsupported_json" ] || [ "$unsupported_json" = "null" ]; then
      unsupported_json="[]"
    fi
  else
    pr_json="null"
    unsupported_json="null"
  fi

  jq -nc \
    --arg status "$status" \
    --argjson pr "$pr_json" \
    --argjson unsupportedFields "$unsupported_json" \
    --arg message "$message" \
    '{status: $status, pr: $pr, unsupported_fields: $unsupportedFields,
      message: (if $message == "" then null else $message end)}'
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the field name GitHub's own
# `gh pr view --json` uses for it. For phase 1 every one of the ten fields
# maps to an identically-spelled gh field, but the table is written out
# EXPLICITLY rather than assumed: it is the single seam a later GitLab or
# Gitea adapter replaces (glab's `description`/`source_branch`/
# `target_branch`, tea's `head`/`base`) without touching the verb body
# around it. An unmapped name prints nothing, so a field this adapter
# cannot express is never silently passed through to gh as-is.
# Usage: _forge_map_pr_field_github <contract-field>
_forge_map_pr_field_github() {
  case "$1" in
    number)      printf 'number' ;;
    url)         printf 'url' ;;
    title)       printf 'title' ;;
    body)        printf 'body' ;;
    state)       printf 'state' ;;
    headRefName) printf 'headRefName' ;;
    baseRefName) printf 'baseRefName' ;;
    files)       printf 'files' ;;
    isDraft)     printf 'isDraft' ;;
    mergeable)   printf 'mergeable' ;;
  esac
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the field name GitLab's own
# `glab mr view <ref> -F json` uses for it. This is the GitLab arm of the
# seam _forge_map_pr_field_github's own header names as "the single seam a
# later GitLab or Gitea adapter replaces"; the two are kept ADJACENT and
# identically case-statement-shaped, ten branches each, so they stay
# diffable side by side.
#
# An unmapped name prints nothing, so a field this adapter cannot express
# is never silently passed through to glab as-is -- the identical
# silent-empty default the github mapper's case statement has.
#
# HOW THIS TABLE IS USED DIFFERS FROM THE GITHUB ONE. gh has a
# `--json <field-list>` selector, so its table names fields to REQUEST.
# glab has no such selector: `-F json` prints the WHOLE marshalled
# document (internal/cmdutils/output_format.go's EnableJSONOutput registers
# `--output`/`-F` over the enum text|json, and
# internal/commands/mr/view/mr_view.go's printJSONMR is literally
# `return opts.io.PrintJSON(mr)` over a *gitlab.MergeRequest), and
# filtering is done afterwards with `--jq`. So every name below is a KEY to
# PICK OUT of that document, never a field to ask for.
#
# `reviews` is deliberately absent and is NOT one of the ten contract
# fields. GitLab merge requests carry `reviewers` -- people ASSIGNED to
# review (BasicMergeRequest.Reviewers, `json:"reviewers"`) -- but have no
# equivalent of GitHub's `reviews` array of SUBMITTED
# APPROVED/CHANGES_REQUESTED verdicts. GitLab models those as approvals, a
# different resource behind its own endpoint
# (MergeRequestsService.GetMergeRequestApprovals). Do not conflate
# reviewers with reviews.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY KEY BELOW, AND NOTE WHAT
# HAS SINCE BEEN LIFTED. glab was NOT installed on the machine this was
# written on, so when this table was authored not one key here had been
# observed coming out of the real binary. The phase-2 github mapper was
# verified against a real gh v2.94.0 before a line of it was written; this
# function could not make that claim at the time.
#
# WHAT WAS LATER OBSERVED, and is therefore no longer under that ceiling: on
# 2026-08-06 every key in this table was checked against a real GitLab CE in
# a container with a real glab 1.112.0. `glab mr view <iid> -F json` returned
# all nine -- iid (a number), web_url, title, description, state,
# source_branch, target_branch, draft (a real boolean) and
# detailed_merge_status -- with the names and types this table asserts, in a
# 64-key document, which is itself the whole-document claim below confirmed.
# `state` came back `opened`, which _forge_map_state already normalizes to
# `open` for gitlab. Nothing in this table needed correcting. (The same run
# against Gitea DID correct a claim there -- see
# _forge_map_pr_field_gitea's header -- so this is a measured result, not a
# rubber stamp.)
#
# WHAT REMAINS UNDER THE CEILING: the review-thread and issue paths, whose
# keys were not exercised. For those the stub still emits whatever its author
# believed, so a wrong key name passes green on both sides.
#
# Every key was originally read off glab's own source and GitLab's API docs: gitlab-org/cli (the glab CLI) and
# gitlab-org/api/client-go (go-gitlab), whose struct tags ARE glab's JSON
# keys precisely because glab marshals *gitlab.MergeRequest directly rather
# than projecting it. Line numbers below are client-go's merge_requests.go
# on main as of 2026-08-05.
#
# number -> iid, NOT id. Both exist on the struct (`ID int64 json:"id"`
# line 81, `IID int64 json:"iid"` line 82). `id` is globally unique across
# the whole GitLab instance; `iid` is the per-project number the user sees
# in the MR URL and types at the CLI. Mapping to `id` would yield a number
# that resolves to a DIFFERENT merge request.
#
# state -> state names the KEY only. GitLab's VALUE vocabulary is its own
# ("opened", not "open"), and normalizing it is _forge_map_state's job --
# it already carries the gitlab arm that folds "opened" to "open".
#
# THE THREE MAPPINGS THAT HAD TO BE DETERMINED RATHER THAN ASSUMED:
#
#   files -> NOTHING, and that is a SETTLED answer rather than an
#     unresolved one: `glab mr view -F json` carries no changed-file list at
#     all, so there is no key to name. Neither MergeRequest nor the
#     BasicMergeRequest it embeds has a Changes field; the only thing close
#     is `ChangesCount string json:"changes_count"` (line 146), a COUNT
#     string, not a file list. A file list requires a SEPARATE call --
#     GetMergeRequestChanges (projects/:id/merge_requests/:iid/changes,
#     merge_requests.go:538) or ListMergeRequestDiffs (.../diffs, line 561)
#     -- and mr_view.go's JSON path issues neither. Emitting nothing is
#     therefore correct, not merely cautious.
#
#   mergeable -> detailed_merge_status. `DetailedMergeStatus string
#     json:"detailed_merge_status"` is on BasicMergeRequest (line 106) and
#     there is NO MergeStatus field on either struct: the single
#     `json:"merge_status"` in the whole file belongs to the unrelated
#     BlockingMergeRequest type (line 1049), so `merge_status` never appears
#     in a `glab mr view -F json` document at all. That settles the older-vs-
#     newer question by absence rather than by preference, and it agrees
#     with GitLab's docs deprecating merge_status in 15.6 in favour of
#     detailed_merge_status. The VALUE is an enum string (e.g. "mergeable",
#     "not_open"), not a boolean -- the same shape GitHub's
#     MERGEABLE/CONFLICTING/UNKNOWN takes, which is why _forge_build_pr_json
#     already carries mergeable as a string.
#
#   isDraft -> draft. BOTH keys are emitted, because glab marshals the whole
#     struct: `Draft bool json:"draft"` on BasicMergeRequest (line 103) and
#     `WorkInProgress bool json:"work_in_progress"` on MergeRequest (line
#     159). The tie is broken by go-gitlab's own comment on the latter,
#     verbatim "// Deprecated: use Draft instead" (line 158), which matches
#     GitLab's API docs ("work_in_progress ... Deprecated. Use draft
#     instead."). So `draft`.
#
# Usage: _forge_map_pr_field_gitlab <contract-field>
_forge_map_pr_field_gitlab() {
  case "$1" in
    number)      printf 'iid' ;;
    url)         printf 'web_url' ;;
    title)       printf 'title' ;;
    body)        printf 'description' ;;
    state)       printf 'state' ;;
    headRefName) printf 'source_branch' ;;
    baseRefName) printf 'target_branch' ;;
    # Deliberately EMPTY, not missing. The branch is kept so the two mappers
    # stay ten-for-ten diffable and a reader meets the omission at the line
    # they look at, rather than only in the header. See the `files` note.
    files)       ;;
    isDraft)     printf 'draft' ;;
    mergeable)   printf 'detailed_merge_status' ;;
  esac
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the key Gitea's own `tea` CLI uses for it.
# This is the gitea arm of the seam _forge_map_pr_field_github's header names
# as "the single seam a later GitLab or Gitea adapter replaces"; the three
# mappers are kept ADJACENT and identically case-statement-shaped, ten
# branches each, so they stay diffable side by side.
#
# An unmapped name prints nothing, so a field this adapter cannot express is
# never silently passed through to tea as-is -- the identical silent-empty
# default the other two mappers' case statements have.
#
# TEA EMITS TWO DIFFERENT JSON SHAPES FOR THE SAME PULL REQUEST, AND EVERY
# KEY BELOW NAMES THE FIRST ONE. This has no gh or glab analogue and is the
# single most likely way to get this adapter wrong:
#
#   DETAIL -- `tea pulls <index> -o json`. One OBJECT with TYPED values,
#     built from the purpose-built `pullData` struct (cmd/pulls.go:29-52):
#     `index` is a JSON number, `mergeable`/`hasMerged` are real booleans,
#     and `base`/`head` are pr.Base.Ref/pr.Head.Ref -- BARE branch names
#     with no `owner:` prefix (cmd/pulls.go:174-177).
#
#   LIST -- `tea pulls list -o json -f <csv>`. A JSON ARRAY whose keys are
#     the --fields names VERBATIM. An earlier revision of this header said
#     SNAKE-CASED, citing toSnakeCase (modules/print/table.go:175-179). That
#     function exists but never fires: no valid --fields name is camelCase,
#     and the two that carry a hyphen keep it. VERIFIED AGAINST A REAL
#     BINARY: `-f index,author-id,base-commit` against Gitea 1.27.1 with tea
#     0.15.1 returned the keys `index`, `author-id`, `base-commit` unchanged.
#     Values are ALWAYS JSON STRINGS, because
#     orderedRow.MarshalJSON (:187-208) marshals a map[string]string. `index`
#     comes back "42", `mergeable` "true", `head` may carry an `owner:branch`
#     prefix for a cross-fork PR (formatPRHead, modules/print/pull.go:83-93).
#
# THIS ADAPTER READS THE DETAIL PATH. _forge_build_pr_json already tolerates
# a string number (`try ($number | tonumber) catch $number`), so the detail
# document's typed values survive the trip through the builder unharmed.
# Pointing a gitea verb at `tea pulls list` output instead would hand
# _forge_pr_view_build_found an array, whose every has($k) probe fails and
# whose every field is therefore skipped -- a silently all-null pr.
#
# TEA HAS A FIELD SELECTOR, SO DO NOT COPY GLAB'S SHAPE BY HABIT. `--fields,
# -f` is a CSV flag over a fixed allowlist (cmd/flags/generic.go:157,
# FieldsFlag) -- closer to gh's `--json <field-list>` than to glab.
# _forge_pr_view_gitlab fetches the WHOLE marshalled document and picks keys
# out of it afterwards (aimi-cli.sh:4688-4701) only because glab has no
# selector at all; that is a workaround for a missing feature, not a house
# style, and a gitea read verb must not inherit it.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY KEY BELOW, AND NOTE WHAT
# HAS SINCE BEEN LIFTED. Every flag, subcommand and JSON key below was first
# read off `gitea/tea` `main` source on 2026-08-06, file and line cited per
# claim, with no binary present -- the same ceiling phase 3 declared for glab
# at :4380-4389, and for the same reason. The suite still only proves WHICH
# arguments this file emits and HOW it parses a fixture.
#
# WHAT WAS LATER OBSERVED, and is therefore no longer under that ceiling:
# on 2026-08-06 the PR shape was checked against a real Gitea 1.27.1 in a
# container with a real tea 0.15.1. `tea pulls <index> -o json` returned
# exactly the 21 keys named below, with `index` a number, `mergeable` and
# `hasMerged` real booleans, and `base`/`head` bare refs. `tea pulls list`
# returned an array whose values are all JSON strings. That run also
# CORRECTED one claim this header had made -- see the LIST note below on
# key names, which source reading had got wrong.
#
# WHAT REMAINS UNDER THE CEILING: the issue-side key names, the review-comment
# listing and resolve round trip, the `owner:` prefix on a cross-fork head,
# and every glab key. For those the stub still emits whatever its author
# believed, so a wrong key name passes green on both sides.
#
# THE THREE MAPPINGS THAT HAD TO BE DETERMINED RATHER THAN ASSUMED:
#
#   number -> index, NOT id. Both exist on pullData (`id` at cmd/pulls.go:30,
#     `index` at :31). `id` is the Gitea instance's globally unique row id;
#     `index` is the per-repository number the user sees in the PR URL and
#     types at the CLI -- the same id-vs-iid distinction GitLab has. Mapping
#     to `id` would yield a number that resolves to a DIFFERENT pull request.
#
#   files -> NOTHING, settled by absence rather than caution. tea exposes
#     `diff` and `patch` (PullFields, modules/print/pull.go:170-196) but both
#     resolve to x.DiffURL/x.PatchURL (:277-280) -- URLs, and the DETAIL
#     document's `diffUrl` likewise. There is no parsed per-file list in
#     either shape, so there is no key to name. Same answer, same grounds, as
#     _forge_map_pr_field_gitlab's own `files` branch above.
#
#   isDraft -> NOTHING. Gitea models a draft as a TITLE PREFIX, not a field:
#     `tea pulls create --draft` prepends "WIP: " to the title
#     (cmd/pulls/create.go:89-91, utils.AddDraftPrefix). pullData carries no
#     draft key and PullFields has no `draft` entry, so the CLI never
#     surfaces one to read back. Deriving it by string-matching a title
#     prefix would be a guess; reporting it in unsupported_fields is the
#     contract's answer for exactly this case.
#
# `state` names the KEY only, and the gitea VALUE vocabulary needs more than
# a table lookup -- see _forge_map_pr_state_gitea directly below, which is
# where `merged` is derived. This mapper answers `state` so the raw value
# still reaches _forge_pr_view_build_found; the merged derivation reads a
# DIFFERENT key (`hasMerged`) and so cannot live in a one-field-one-key
# table.
#
# THIS ONCE CONTRADICTED commands/references/forge-contract.md, AND NO LONGER
# DOES. That document used to state tea "does not expose a distinct `merged`
# value", that a merged PR "reads as `closed` under tea's own field list", and
# that an adapter "should normalize tea's `closed` straight through". All
# three are falsified by source: formatPRState (modules/print/pull.go:95-100)
# returns "merged" whenever pr.Merged != nil, and the DETAIL path carries
# `hasMerged`/`mergedAt` alongside the raw state (cmd/pulls.go:33,46,47). The
# correct behaviour was implemented here first and the ruling was deleted
# afterwards, so the contract's State Mapping section now describes this code
# rather than misdirecting the next adapter author away from it.
#
# Usage: _forge_map_pr_field_gitea <contract-field>
_forge_map_pr_field_gitea() {
  case "$1" in
    number)      printf 'index' ;;
    url)         printf 'url' ;;
    title)       printf 'title' ;;
    body)        printf 'body' ;;
    state)       printf 'state' ;;
    headRefName) printf 'head' ;;
    baseRefName) printf 'base' ;;
    # Deliberately EMPTY, not missing. The branch is kept so the three mappers
    # stay ten-for-ten diffable and a reader meets the omission at the line
    # they look at, rather than only in the header. `diff`/`patch`/`diffUrl`
    # are URLs, not a per-file list -- see the `files` note.
    files)       ;;
    # Deliberately EMPTY too: Gitea has no draft FIELD at all, only the
    # "WIP: " title prefix `--draft` writes. See the `isDraft` note.
    isDraft)     ;;
    mergeable)   printf 'mergeable' ;;
  esac
}

# Normalizes a `tea pulls <index> -o json` DETAIL document's state into the
# contract vocabulary, printing `merged` for a merged pull request.
#
# This is a SIBLING of _forge_map_pr_field_gitea rather than a branch inside
# it, because the merged answer reads a DIFFERENT key (`hasMerged`) than the
# `state` key, which a one-field-one-key table cannot express. It is also
# deliberately NOT a gitea arm of _forge_map_state: that function maps a raw
# VALUE and knows nothing about documents, and _forge_pr_view_build_found's
# own header promises its body stays forge-independent by construction. So
# the derivation lives here, in the adapter, and _forge_map_state stays
# gitea-free -- the same separation of "name the key" from "normalize the
# value" the build_found body already keeps (:4509-4514).
#
# has("hasMerged") rather than a bare index mirrors _forge_pr_view_build_found's
# own rule (:4474-4477): an absent key must not be collapsed with an explicit
# null, and neither may invent `merged`. A document that carries no hasMerged
# at all passes its raw state through untouched.
#
# Ceiling and source citations: see _forge_map_pr_field_gitea's header above.
# Usage: _forge_map_pr_state_gitea <detail-json>
_forge_map_pr_state_gitea() {
  local doc="${1:-}" merged raw

  merged=$(printf '%s' "$doc" | jq -r \
    'if has("hasMerged") then (.hasMerged | tostring) else "" end' 2>/dev/null) || merged=""
  if [ "$merged" = "true" ]; then
    printf 'merged'
    return 0
  fi

  raw=$(printf '%s' "$doc" | jq -r \
    'if has("state") then (.state | if . == null then "" else tostring end) else "" end' 2>/dev/null) || raw=""
  _forge_map_state gitea "$raw"
}

# THE ONE found-envelope construction, shared by every forge-pr-view adapter.
# Takes a forge label, the adapter's RAW response document, and the caller's
# requested contract-field list, and emits the finished
# {status:"found", pr, unsupported_fields, message:null} envelope.
#
# It exists so the three-way envelope is built once rather than copied per
# adapter. Everything below is forge-independent BY CONSTRUCTION: the only
# per-forge knowledge is the single _forge_map_pr_field_* lookup and the
# _forge_map_state forge label, both selected from $forge here. An adapter
# body therefore never re-derives the projection, the unsupported_fields
# intersection, or the null-vs-absent rule -- it fetches a document and hands
# it over.
#
# A CONTRACT FIELD THE MAPPER ANSWERS EMPTY FOR IS REPORTED ABSENT, NEVER
# GUESSED. The `[ -n "$native" ] || continue` below is that rule: on GitLab
# `files` maps to nothing (the document carries no changed-file list at all),
# so no flag reaches _forge_build_pr_json, which then marks `files` in
# unsupported_fields and leaves its value null. That is a reported absence,
# not an invented value.
#
# has() rather than a bare index keeps "the forge omitted this key entirely"
# (unsupported -- null AND named in unsupported_fields) distinguishable from
# "the forge returned this key with an explicit null" (supported -- null but
# NOT named), which a bare index collapses into one indistinguishable null.
#
# Usage: _forge_pr_view_build_found <forge> <raw-json-document> <fields-csv>
_forge_pr_view_build_found() {
  local forge="$1" doc="$2" fields_csv="$3"

  local -a requested=()
  local old_ifs="$IFS"
  IFS=','
  read -ra requested <<< "$fields_csv"
  IFS="$old_ifs"

  local -a builder_args=()
  local field native present raw_value
  for field in "${requested[@]}"; do
    case "$forge" in
      github) native=$(_forge_map_pr_field_github "$field") ;;
      gitlab) native=$(_forge_map_pr_field_gitlab "$field") ;;
      gitea)  native=$(_forge_map_pr_field_gitea "$field") ;;
      *)      native="" ;;
    esac
    [ -n "$native" ] || continue
    present=$(printf '%s' "$doc" | jq -r --arg k "$native" 'has($k)' 2>/dev/null) || present="false"
    [ "$present" = "true" ] || continue
    case "$field" in
      # Scalars reach the builder as strings. `if . == null` rather than
      # `// ""` deliberately: `//` also swallows a legitimate `false`, which
      # mergeable can genuinely carry on a forge that reports it as a boolean
      # rather than GitHub's MERGEABLE/CONFLICTING/UNKNOWN enum or GitLab's
      # detailed_merge_status enum.
      number|url|title|body|headRefName|baseRefName|mergeable)
        raw_value=$(printf '%s' "$doc" | jq -r --arg k "$native" '.[$k] | if . == null then "" else tostring end')
        ;;
      state)
        raw_value=$(printf '%s' "$doc" | jq -r --arg k "$native" '.[$k] | if . == null then "" else tostring end')
        # The KEY is what the mapper answered; the VALUE vocabulary is a
        # separate job -- this is where GitLab's "opened" becomes "open".
        raw_value=$(_forge_map_state "$forge" "$raw_value")
        ;;
      # JSON-valued fields reach the builder as raw JSON (--argjson on the
      # other side), so an explicit null stays the JSON literal `null`.
      files|isDraft)
        raw_value=$(printf '%s' "$doc" | jq -c --arg k "$native" '.[$k]')
        ;;
    esac
    case "$field" in
      number)      builder_args+=(--number "$raw_value") ;;
      url)         builder_args+=(--url "$raw_value") ;;
      title)       builder_args+=(--title "$raw_value") ;;
      body)        builder_args+=(--body "$raw_value") ;;
      state)       builder_args+=(--state "$raw_value") ;;
      headRefName) builder_args+=(--head-ref-name "$raw_value") ;;
      baseRefName) builder_args+=(--base-ref-name "$raw_value") ;;
      files)       builder_args+=(--files "$raw_value") ;;
      isDraft)     builder_args+=(--is-draft "$raw_value") ;;
      mergeable)   builder_args+=(--mergeable "$raw_value") ;;
    esac
  done

  local pr_full pr_json unsupported_json fields_json
  pr_full=$(_forge_build_pr_json ${builder_args[@]+"${builder_args[@]}"})
  fields_json=$(printf '%s' "$fields_csv" | jq -Rc 'split(",")')

  # Project the builder's fixed ten-key output down to exactly the keys this
  # caller asked for, in the order it asked for them -- the
  # never-pay-for-files-you-did-not-ask-for behavior this verb's --include
  # selector exists for. The builder's superset is never emitted.
  pr_json=$(printf '%s' "$pr_full" | jq -c --argjson keys "$fields_json" '
    . as $src | reduce $keys[] as $k ({}; . + {($k): $src[$k]})
  ')

  # ...and intersect the builder's own unsupported_fields with that same
  # requested list: the builder always flags an unpassed capability-gated
  # flag, but a field the caller never included is simply not part of this
  # answer and must not be reported as unsupported.
  unsupported_json=$(printf '%s' "$pr_full" | jq -c --argjson keys "$fields_json" '
    [.unsupported_fields[] | . as $f | select($keys | index($f))]
  ')

  _forge_pr_view_emit "found" "$pr_json" "$unsupported_json" ""
}

# github adapter for forge-pr-view. <ref> is a PR number or a branch name
# (already validated by cmd_forge_pr_view before this ever runs);
# <fields_csv> is the comma-joined list of NORMALIZED PR contract field
# names (caller's --include set, or the default cheap set) -- never gh's own
# vocabulary. Every crossing of that boundary goes through
# _forge_map_pr_field_github: contract name -> gh name on the way in (to
# build gh's --json list), gh name -> contract name on the way out (to pick
# the value out of gh's response). Captures gh's stdout and stderr on
# separate variables (this file runs under set -euo pipefail -- rc is
# pre-initialized and captured with `|| rc=$?`, mirroring
# roadmap.py's verify_creates_one capture pattern) so a legitimate non-zero gh
# exit never aborts the script.
_forge_pr_view_github() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more PRs -- i.e. existence is a confirmed structural fact, not an
  # inference. Consulted after gh pr view to keep a view failure from being
  # reinterpreted as not_found.
  local list_confirmed_exists=false

  # Translate the caller's contract field names to gh's own BEFORE the
  # --json field list is ever built, so gh never sees a name it does not
  # know and this adapter never assumes the two vocabularies agree.
  local -a requested=() gh_fields=()
  local old_ifs="$IFS"
  IFS=','
  read -ra requested <<< "$fields_csv"
  IFS="$old_ifs"

  local field gh_field
  for field in "${requested[@]}"; do
    gh_field=$(_forge_map_pr_field_github "$field")
    [ -n "$gh_field" ] && gh_fields+=("$gh_field")
  done

  local gh_fields_csv
  gh_fields_csv=$(IFS=','; printf '%s' "${gh_fields[*]:-}")

  # --- structural existence probe, FIRST for a branch ref ----------------
  # `gh pr list --head <branch> --json number` returns `[]` at exit 0 when no
  # PR exists -- a structural fact in JSON rather than a string in a message,
  # so it survives a gh release that rewords its own stderr or a non-English
  # locale. `--state all` so a closed/merged PR still counts as found (gh pr
  # list defaults to open-only, which would otherwise misreport a closed PR's
  # branch as not_found). `--head` takes a branch name, never a PR number, so
  # a NUMERIC ref skips this probe entirely and goes straight to gh pr view
  # plus the stderr tier below -- unchanged in both directions by this
  # reordering.
  #
  # WHY IT RUNS BEFORE gh pr view RATHER THAN AS ITS BACKSTOP: on the "no PR
  # yet" path -- the dominant case in aggregate, since execute.md's per-phase
  # idempotency pre-check runs this exact lookup on every phase close whether
  # or not a PR already exists -- asking view first meant paying a doomed
  # round trip and then paying the probe anyway to confirm what it meant. Two
  # calls to learn "no". Probing first answers that structurally in one, and
  # gh pr view is never invoked at all.
  #
  # The accepted, deliberate trade-off: a FOUND branch-ref lookup now costs
  # two calls (probe, then view for the actual fields) where it used to cost
  # one. That is the price of making absence cheap, and absence is the common
  # case.
  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count=""
    list_out=$(gh pr list --head "$ref" --state all --json number 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      list_count=$(printf '%s' "$list_out" | jq 'length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the same view-plus-stderr
      # path a failed probe takes.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- gh pr view "$ref" --json "$gh_fields_csv" || true

  if [ "$rc" -eq 0 ]; then
    # Normalize gh's raw response through the ONE shared found-envelope
    # builder rather than re-subsetting gh's own JSON here: state is
    # case-folded through the same _forge_map_state call forge-issue-view
    # applies, every capability-gated field is flagged by the builder's own
    # presence rule, and the projection/intersection logic is the same code
    # the gitlab adapter runs.
    _forge_pr_view_build_found "github" "$stdout" "$fields_csv"
    return 0
  fi

  # --- not_found detection ---------------------------------------------
  # THE THREE-WAY STATUS MUST SURVIVE THE REORDER. The probe already said
  # this PR exists, structurally; gh pr view then failed anyway (a transient
  # error, or a race between the two calls). That is a tool failure and
  # nothing else -- reporting not_found here would take the one case where
  # absence has been positively DISPROVEN and report it as absence, which is
  # precisely the conflation this verb exists to prevent. The stderr-text
  # tier below is skipped too: gh pr view's own wording cannot outvote a
  # structural fact, not even when it happens to say "no pull requests
  # found".
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback: gh's own no-pull-requests-found wording. Kept
  # strictly as a backstop for when the structural probe above could not
  # confirm anything (a numeric ref, or the list probe itself failing) --
  # never the primary signal, since a translatable/rewordable string is
  # exactly the fragility this verb exists to avoid.
  if printf '%s' "$stderr" | grep -qi "no pull requests\? found"; then
    _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. evidence carries
  # gh's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# gitlab adapter for forge-pr-view. Same signature and same three outcomes as
# _forge_pr_view_github above, and the two are deliberately kept adjacent and
# structurally parallel so a reader can diff them: probe, view, classify.
#
# THE ONE ASYMMETRY THAT MATTERS, AND THE SINGLE MOST LIKELY WAY TO GET THIS
# ADAPTER WRONG: gh has a `--json <field-list>` SELECTOR, so the github
# adapter above translates the caller's contract fields into gh's vocabulary
# and asks gh for exactly those. glab has NO such selector on any read
# command. Its entire output interface is
#   -F, --output string   Format output as: text, json. (default "text")
#       --jq string       Filter JSON output with a jq expression.
# (docs/source/mr/view.md), and internal/commands/mr/view/mr_view.go's JSON
# path is literally `return opts.io.PrintJSON(mr)` over a
# *gitlab.MergeRequest -- the WHOLE marshalled document, every time.
# Passing a field list to glab as if it were gh would hand it an argument it
# does not define. So this adapter asks for `-F json` and PICKS keys out of
# the returned document afterwards, via _forge_map_pr_field_gitlab. There is
# no per-field cost to save on the request side, so no field list is built.
#
# not_found IS DETECTED STRUCTURALLY FIRST, exactly like the github arm:
# `glab mr list --source-branch <branch> --all -F json` returns `[]` at exit 0
# when no merge request exists for that branch -- a fact in JSON rather than a
# string in a message, so it survives a glab release that rewords its own
# stderr or a non-English locale. `--all` because `glab mr list` defaults to
# opened-only, which would otherwise misreport a merged MR's branch as absent.
# `--source-branch` takes a branch name, never an MR IID, so a NUMERIC ref
# skips the probe entirely -- identical to `--head`'s role above.
#
# CONFLATING not_found WITH error IS THE DEFECT THIS VERB EXISTS TO PREVENT,
# and that holds on GitLab too: when the probe positively CONFIRMED the MR
# exists and `glab mr view` then failed anyway, this reports error, never
# not_found, and does not consult stderr wording at all -- a string cannot
# outvote a structural fact.
#
# VERIFICATION CEILING: glab is not installed on the machine this was written
# on; every flag and key above is read off glab's own docs and source, never
# observed coming out of the real binary. Same declared ceiling as
# _forge_map_pr_field_gitlab's header.
_forge_pr_view_gitlab() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more merge requests -- i.e. existence is a confirmed structural fact, not
  # an inference.
  local list_confirmed_exists=false

  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count=""
    list_out=$(glab mr list --source-branch "$ref" --all -F json 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      list_count=$(printf '%s' "$list_out" | jq 'length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no merge request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the view-plus-stderr path.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- glab mr view "$ref" -F json || true

  if [ "$rc" -eq 0 ]; then
    # The SAME found-envelope builder the github arm calls, differing only in
    # the forge label -- which is what selects _forge_map_pr_field_gitlab for
    # the key lookup and the gitlab arm of _forge_map_state for the value.
    # `files` is the field that mapper answers empty for, so it comes back
    # null AND named in unsupported_fields: reported absent, never guessed.
    _forge_pr_view_build_found "gitlab" "$stdout" "$fields_csv"
    return 0
  fi

  # A structurally CONFIRMED existence outranks any stderr text, including
  # text that happens to say 404. See the header.
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback only: glab surfaces a missing merge request as the
  # API's own 404. Kept strictly as a backstop for when the structural probe
  # could not confirm anything (a numeric ref, or the probe itself failing),
  # never as the primary signal.
  if printf '%s' "$stderr" | grep -qiE '404|not found'; then
    _forge_pr_view_emit "not_found" "null" "null" "no merge request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. The message carries
  # glab's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# gitea adapter for forge-pr-view. Same signature and same three outcomes as
# the github and gitlab arms above, and all three are deliberately kept
# adjacent and structurally parallel so a reader can diff them: probe, view,
# classify.
#
# TWO ASYMMETRIES MAKE `tea` NOT `glab`, AND CARRYING THE GITLAB SHAPE OVER
# BY HABIT IS THE SINGLE MOST LIKELY WAY TO GET THIS ADAPTER WRONG.
#
# (a) `tea` HAS a field selector. `--fields, -f` is a CSV flag over a fixed
# allowlist (cmd/flags/generic.go:157). _forge_pr_view_gitlab fetches the
# whole document and picks keys afterwards ONLY because glab has no selector
# at all; that is not a house style to copy. So the LIST probe below asks for
# exactly the two fields it consumes. But the selector does NOT extend to the
# detail path: `tea pulls <index> -o json` emits a fixed `pullData`
# projection (cmd/pulls.go:29-52, routed at :88-93), so no `-f` belongs on
# that invocation either -- and a gh-style `--json <field-list>` belongs on
# neither, because `tea` defines no such flag anywhere.
#
# (b) `tea` emits TWO DIFFERENT JSON SHAPES for the same resource, chosen by
# whether an index argument was passed. This has no gh or glab analogue.
#   DETAIL -- `tea pulls <index> -o json`: ONE OBJECT with TYPED values
#     (index is a number, mergeable/hasMerged are real booleans), head/base
#     are BARE refs (cmd/pulls.go:174-177).
#   LIST -- `tea pulls list -o json -f <csv>`: a JSON ARRAY whose keys are
#     the --fields names VERBATIM -- NOT snake-cased; see
#     _forge_map_pr_field_gitea's header for the measurement that corrected
#     this -- and whose values are ALWAYS STRINGS
#     (modules/print/table.go:175-208), and whose `head` may carry an
#     `owner:` prefix for a cross-fork pull request (formatPRHead,
#     modules/print/pull.go:83-93).
# This function uses DETAIL for the found path and LIST for the structural
# probe, and must never mix their assumptions.
#
# not_found IS ESTABLISHED STRUCTURALLY, exactly like the two arms above,
# and it has to be: `tea` exits 1 UNIFORMLY for every error (main.go:18-30)
# with no distinct "not found" code at all -- the precise conflation this
# verb exists to defeat. But the probe is HARDER here than on either other
# forge, because `tea pulls list` has NO head/source-branch filter
# (cmd/pulls/list.go:31 carries only --fields plus --state/--page/--limit).
# So the listing is fetched with `--state all` -- a merged or closed pull
# request must still count as found -- and filtered LOCALLY. The local
# comparison is on the SUFFIX after the last `:`, never plain equality: a
# cross-fork row spells its head `contributor:feat-x`, and reporting that as
# absent would invite a duplicate pull request. Git refs cannot contain `:`,
# so the split is unambiguous.
#
# THE PROBE ALSO RESOLVES THE INDEX. `tea pulls <arg>` takes an INDEX, never
# a branch name, so a branch ref could not address the detail call at all
# without this step -- which is why the probe selects `index` alongside
# `head`. A purely numeric ref addresses the pull request directly and skips
# the probe entirely, the same way `--head`/`--source-branch` are skipped
# above.
#
# CONFLATING not_found WITH error IS THE DEFECT THIS VERB EXISTS TO PREVENT:
# when the probe positively CONFIRMED the pull request exists and the detail
# call then failed anyway, this reports error and does not consult stderr
# wording at all -- not even when that wording happens to say 404. A string
# cannot outvote a structural fact.
#
# NO CREDENTIAL IS BOUND ON ANY INVOCATION HERE. `tea` honours GH_TOKEN when
# GITEA_INSTANCE_URL is also set (modules/context/context_login.go:15-51), so
# a prefix assignment copied from the GitHub write path would hand a GitHub
# token to a Gitea instance.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. The tests prove WHICH ARGV this function emits and
# HOW it parses a fixture -- never what real `tea` does with them. Same
# declared ceiling _forge_map_pr_field_gitea's header states.
_forge_pr_view_gitea() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more matching pull requests -- i.e. existence is a confirmed structural
  # fact, not an inference.
  local list_confirmed_exists=false
  # The argument the DETAIL call is addressed with. A numeric ref is already
  # an index; a branch ref becomes one only if the probe resolves it.
  local detail_ref="$ref"

  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count="" list_index=""
    list_out=$(tea pulls list --state all -f index,head -o json 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      # The local head filter, in the LIST vocabulary: every value is a
      # string, and `head` may be `owner:branch`. `sub("^.*:"; "")` is greedy
      # and therefore strips through the LAST colon, leaving a bare ref
      # untouched when there is none.
      list_count=$(printf '%s' "$list_out" | jq --arg ref "$ref" '
        [ .[]
          | select(type == "object")
          | select((((.head // "") | tostring) | sub("^.*:"; "")) == $ref) ] | length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the same detail-plus-
      # stderr path a failed probe takes.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
        list_index=$(printf '%s' "$list_out" | jq -r --arg ref "$ref" '
          [ .[]
            | select(type == "object")
            | select((((.head // "") | tostring) | sub("^.*:"; "")) == $ref) ][0].index // "" | tostring' 2>/dev/null) || list_index=""
        [ -n "$list_index" ] && detail_ref="$list_index"
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- tea pulls "$detail_ref" -o json || true

  if [ "$rc" -eq 0 ]; then
    # `merged` is DERIVED here, in the adapter, and nowhere else in this
    # file. tea's DETAIL `state` is `pr.State` raw -- open/closed only
    # (cmd/pulls.go:33) -- while merged-ness lives in the separate
    # `hasMerged` boolean (:46). Reading a second key is exactly what a
    # one-field-one-key mapper cannot express, which is why
    # _forge_map_pr_state_gitea is a sibling of the mapper rather than a
    # branch inside it, and why _forge_map_state stays gitea-free: that
    # function normalizes SPELLING and must not invent a value the source
    # data did not provide. The rewritten document is then handed to the ONE
    # shared found-envelope builder, which does the key lookup through
    # _forge_map_pr_field_gitea -- this arm builds no key table of its own.
    local state_norm normalized
    state_norm=$(_forge_map_pr_state_gitea "$stdout")
    normalized=$(printf '%s' "$stdout" | jq -c --arg state "$state_norm" '
      if (type == "object" and has("state")) then .state = $state else . end' 2>/dev/null) || normalized="$stdout"
    [ -n "$normalized" ] || normalized="$stdout"
    _forge_pr_view_build_found "gitea" "$normalized" "$fields_csv"
    return 0
  fi

  # A structurally CONFIRMED existence outranks any stderr text, including
  # text that happens to say 404. See the header.
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback only, for when the structural probe could not confirm
  # anything (a numeric ref, or the probe itself failing). `tea` has no
  # not-found exit code, so this reads its prose -- which is exactly the
  # fragility the probe above exists to avoid, hence backstop-only.
  if printf '%s' "$stderr" | grep -qiE '404|not found'; then
    _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. The message carries
  # tea's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# Field-selectable, three-way-status PR lookup. See this section's header
# comment for the defect this fixes and why its envelope differs from the
# generic forge-contract.md three-way envelope.
# Usage: aimi-cli.sh forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]
# --include is a comma-separated subset of the TEN normalized PR contract
# fields (forge-contract.md's "Normalized PR Field Set"): number, url,
# title, body, state, headRefName, baseRefName, files, isDraft, mergeable.
# Defaults to the portable core (number,url,title,body,state,headRefName,
# baseRefName) when omitted -- the three capability-gated fields (files,
# isDraft, mergeable) stay opt-in-only so a caller that only wants url never
# triggers the more expensive per-file lookup.
#
# gh-only names with no PR-contract equivalent (reviews, comments) are NOT
# accepted here: this selector runs on the contract's vocabulary, not gh's,
# and a name the contract cannot express would have no meaning on a later
# gitlab/gitea adapter. A verb needing per-reviewer detail consumes the
# forge-native object instead (forge-contract.md's Review/Approval Envelope
# section says so explicitly).
cmd_forge_pr_view() {
  check_jq

  local pr_ref="" include_raw="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)      shift; pr_ref="${1:-}" ;;
      --include) shift; include_raw="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-view: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$pr_ref" ]; then
    echo "Usage: aimi-cli.sh forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]" >&2
    exit 1
  fi

  # Validate --pr before it is ever interpolated into a gh invocation:
  # digits-only (a PR number) or the repo-wide branch-name regex.
  if ! [[ "$pr_ref" =~ ^[0-9]+$ ]] && ! [[ "$pr_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-view: invalid --pr value: $pr_ref" >&2
    exit 1
  fi

  # --include: comma-separated field list (IFS=',' split, matching the
  # decoration-token split at aimi-cli.sh:1727). An unrecognized field name
  # is CLI misuse (exit 1) -- never folded into the substantive result.
  local -a requested_fields=()
  if [ -n "$include_raw" ]; then
    local old_ifs="$IFS"
    IFS=','
    read -ra requested_fields <<< "$include_raw"
    IFS="$old_ifs"
  else
    requested_fields=(number url title body state headRefName baseRefName)
  fi

  local field known
  for field in "${requested_fields[@]}"; do
    known=false
    case "$field" in
      number|url|title|body|state|headRefName|baseRefName|files|isDraft|mergeable) known=true ;;
    esac
    if [ "$known" = false ]; then
      echo "Error: forge-pr-view: unknown --include field: $field" >&2
      exit 1
    fi
  done

  local fields_csv
  fields_csv=$(IFS=','; echo "${requested_fields[*]}")

  local forge=""
  _detect_forge_type forge

  # Each arm gates on the binary THAT forge needs -- gh for github, glab for
  # gitlab, tea for gitea -- through the shared _forge_bin_check in its quiet
  # mode, and its degraded message names that same binary. A GitLab user is
  # never told to install gh, and neither is a Gitea one. The `*)` arm is
  # still reachable, by `unknown`.
  case "$forge" in
    github)
      if _forge_bin_check gh quiet github; then
        _forge_pr_view_github "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "gh not found on PATH -- this github operation cannot run automatically."
      fi
      ;;
    gitlab)
      if _forge_bin_check glab quiet gitlab; then
        _forge_pr_view_gitlab "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "glab not found on PATH -- this gitlab operation cannot run automatically."
      fi
      ;;
    gitea)
      if _forge_bin_check tea quiet gitea; then
        _forge_pr_view_gitea "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "tea not found on PATH -- this gitea operation cannot run automatically."
      fi
      ;;
    *)
      _forge_pr_view_emit "error" "null" "null" "no forge-pr-view adapter for the '$forge' forge yet."
      ;;
  esac
}

# ============================================================================
# forge-pr-create / forge-pr-edit (US-005)
# ============================================================================
# The first WRITE verbs in this phase that create/mutate a pull request.
# Built entirely on US-001's detect-forge, US-002's shared degradation gate
# (_forge_bin_check), and US-004's forge-pr-view -- called here as an
# in-process function, never a `$AIMI_CLI forge-pr-view` subprocess -- for
# both the idempotency check and the post-create structured re-read. Neither
# helper below re-derives detect-forge or forge-pr-view's own lookup logic.
#
# THE DEFECT THIS PAIR EXISTS TO FIX: commands/open-pr.md's `gh pr create`
# call (open-pr.md:355) does not capture its own output, so PR_URL/PR_BODY
# (read later at :465/:479) are assigned by no block in that file --
# grandfathered in scripts/command-blocks-baseline.txt as "read but never
# assigned". forge-pr-create emits forge-contract.md's write-verb envelope
# ({status, data: {url, number}, message}) as compact JSON so a caller in an
# isolated Bash block can capture the created PR's identity by plain
# assignment. Rewriting open-pr.md itself is story 08's job, not this one --
# this section only makes the value available.
#
# EXIT CONTRACT DIFFERS FROM forge-issue-create ON PURPOSE: forge-issue-
# create is a soft-fail verb (exit always 0, caller branches on `status`)
# because a failed backend issue must never block PR creation. Opening or
# editing the PR itself has no such fallback -- execute.md's per-repository
# PR-creation step needs a real non-zero exit so its own per-repository
# failure isolation (report that repository's failure verbatim, move on to
# the next repository) keeps working once it migrates onto this verb. Both
# functions below NEVER retry, NEVER prompt interactively, and NEVER mutate
# any phase/story completed status -- only the caller does that, and only
# after observing the non-zero exit.
#
# IDENTITY: exactly like forge-issue-create, neither cmd_forge_pr_create nor
# cmd_forge_pr_edit accepts a --token (or similarly credential-shaped) flag.
# Any acting-account identity (e.g. AIMI_FORGE_IDENTITY, or a GH_TOKEN a
# caller exported before invoking this CLI) reaches the child gh process
# purely by environment-variable inheritance -- no extra code is needed here
# to pass it along, and neither function ever echoes or logs one verbatim.
# Phase 2's per-repository account selection built on that signature without
# retrofitting it: both functions below now resolve _forge_account_override
# once and apply it as a bash PREFIX ASSIGNMENT on each gh write and on the
# forge-pr-view reads made as part of the same operation. See the ROUTING
# RULE block above the forge-auth-status section for the full statement.

# Prints the MANDATORY manual-fallback instructions (forge-contract.md's
# Degradation Contract, mandatory mode) for every forge-pr-create/forge-pr-
# edit failure path -- an unsupported forge, a missing gh binary, or the gh
# call itself failing all funnel through this one function so the wording
# is identical regardless of WHY automatic create/edit did not happen.
# Always stderr, never stdout, so a caller consuming this verb's JSON result
# on stdout never has to filter prose out of its own data.
#
# mode: create | edit.
#   create -- prints the git push command plus a manual `gh pr create`
#             invocation (AC6's "the git push command"), and, when
#             forge-repo-info can resolve owner/repo (its own local-parse
#             fallback needs only the git remote, not gh -- see US-003),
#             the compare URL a human can open directly (AC6's "the
#             compare-URL ... command").
#   edit   -- prints a manual `gh pr edit` invocation and, when resolvable,
#             the PR's own URL (AC6's "... or edit command").
# repo-info is queried in-process (a direct function call, never a
# subprocess) and is itself best-effort here: when it cannot resolve
# owner/repo (no adapter, gh absent, no origin), the URL line is simply
# omitted rather than guessing a wrong one.
_forge_pr_write_print_manual() {
  local mode="$1" forge="$2" base="$3" head_or_number="$4" body="$5" title="${6:-}"

  local repo_info="" owner="" repo="" host=""
  repo_info=$(_forge_repo_info 2>/dev/null) || repo_info=""
  if [ -n "$repo_info" ] && [ "$(printf '%s' "$repo_info" | jq -r '.status' 2>/dev/null)" = "found" ]; then
    owner=$(printf '%s' "$repo_info" | jq -r '.data.owner // empty')
    repo=$(printf '%s' "$repo_info" | jq -r '.data.repo // empty')
    host=$(printf '%s' "$repo_info" | jq -r '.data.host // empty')
  fi
  if [ -z "$host" ]; then
    # Per-forge default rather than a single github.com constant: on a GitLab
    # repository whose host could not be resolved, printing a github.com URL
    # would be actively misleading rather than merely unhelpful. The same
    # applies to Gitea/Forgejo -- gitea.com is Gitea's own SaaS host, and
    # falling through to github.com here was a live wrong-output bug for every
    # Gitea remote whose host could not be resolved, not a cosmetic default.
    case "$forge" in
      gitlab) host="gitlab.com" ;;
      gitea)  host="gitea.com" ;;
      *)      host="github.com" ;;
    esac
  fi

  {
    if [ "$forge" = "gitlab" ]; then
      # GitLab arm. Three things differ from the github arm below and every
      # one of them is a correctness matter, not a cosmetic one:
      #   - the noun is "merge request", not "pull request";
      #   - the CLI is glab, and the invocation printed here CARRIES -y for
      #     the same reason the automatic one does (see the GitLab write
      #     adapters section) -- a human who copy-pastes this line into an
      #     unattended script must not inherit the hang;
      #   - GitLab's web paths are /-/merge_requests/... , and the "open a new
      #     MR" form is a query-string on /-/merge_requests/new rather than
      #     GitHub's /compare/base...head?expand=1.
      if [ "$mode" = "create" ]; then
        echo "Warning: could not create this gitlab merge request automatically -- create it yourself with:"
        echo "  git push -u origin $head_or_number"
        echo "  glab mr create -y --title \"$title\" --source-branch $head_or_number --target-branch $base --description ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=$head_or_number&merge_request%5Btarget_branch%5D=$base"
        fi
      else
        echo "Warning: could not edit this gitlab merge request automatically -- edit it yourself with:"
        echo "  glab mr update $head_or_number -y --description ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/-/merge_requests/$head_or_number"
        fi
      fi
    elif [ "$forge" = "gitea" ]; then
      # Gitea/Forgejo arm. THE NOUN STAYS "pull request" -- do NOT "fix" this
      # into merge-request wording by symmetry with the gitlab arm above.
      # Gitea calls them pull requests, exactly like GitHub; only GitLab says
      # merge request. Three things do differ from the github arm below, and
      # every one of them is a correctness matter:
      #   - the CLI is tea, and its flag names are tea's own: -t/--title and
      #     -d/--description, never gh's --body, plus --head in its LONG FORM
      #     ONLY (tea gives it no short alias, and -h is urfave/cli's help
      #     flag) and -b/--base. See the Gitea write adapters section header.
      #   - Gitea's compare form is /<owner>/<repo>/compare/<base>...<head>
      #     with no ?expand=1 -- that query parameter is GitHub's.
      #   - Gitea's pull-request path is /<owner>/<repo>/pulls/<number>, with
      #     an "s". GitHub's singular /pull/<number> 404s on a Gitea instance.
      if [ "$mode" = "create" ]; then
        echo "Warning: could not create this gitea pull request automatically -- create it yourself with:"
        echo "  git push -u origin $head_or_number"
        echo "  tea pulls create -t \"$title\" --head $head_or_number -b $base -d ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/compare/$base...$head_or_number"
        fi
      else
        echo "Warning: could not edit this gitea pull request automatically -- edit it yourself with:"
        echo "  tea pulls edit $head_or_number -d ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/pulls/$head_or_number"
        fi
      fi
    elif [ "$mode" = "create" ]; then
      echo "Warning: could not create this $forge pull request automatically -- create it yourself with:"
      echo "  git push -u origin $head_or_number"
      echo "  gh pr create --title \"$title\" --base $base --head $head_or_number --body ..."
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/compare/$base...$head_or_number?expand=1"
      fi
    else
      echo "Warning: could not edit this $forge pull request automatically -- edit it yourself with:"
      echo "  gh pr edit $head_or_number --body ..."
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/pull/$head_or_number"
      fi
    fi
    echo "  Body:"
    printf '%s\n' "$body" | sed 's/^/    /'
  } >&2
}

# ============================================================================
# GitLab write adapters — forge-pr-create, forge-pr-edit, forge-issue-create
# ============================================================================
# The gitlab arms of this file's THREE write verbs, kept together in one
# section rather than scattered into each verb's body so the one rule they
# all obey is stated once and is impossible to read past.
#
# THE RULE: EVERY glab WRITE INVOCATION CARRIES -y (--yes). NO EXCEPTIONS.
#
# `glab mr create`, `glab mr update` and `glab issue create` each PROMPT for
# a submission confirmation unless -y is passed (glab's own flag help:
# "Skip submission confirmation prompt" on mr create, "Skip confirmation
# prompt" on mr update, "Don't prompt for confirmation to submit the issue"
# on issue create). `gh pr create` has no such flag and needs none, so the
# habit carried over from the github adapter next door does NOT produce an
# error here -- it produces a HANG, forever, with no output explaining why,
# in an autonomous run with nobody present to answer. A hang is the single
# hardest failure in this system to diagnose, which is why -y is written
# FIRST on every invocation below, immediately after the subcommand, where
# a reviewer meets it before any other flag.
#
# GLAB'S FLAG NAMES ARE NOT gh'S. Verified against glab's own published
# command reference (docs/source/mr/create.md, docs/source/mr/update.md,
# docs/source/issue/create.md):
#   -t/--title           (same spelling as gh)
#   -d/--description     NOT --body
#   -s/--source-branch   NOT --head
#   -b/--target-branch   NOT --base
#   -y/--yes             no gh equivalent at all
# `glab mr update` takes the merge request as a POSITIONAL argument
# ([<id> | <branch>]) and accepts no --source-branch/--target-branch pair.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY BEHAVIOR BELOW. glab was
# NOT installed on the machine this was written on; that is this phase's
# declared ceiling, not an oversight. Not one invocation here has been
# observed against the real binary. Flag names and prompt behavior come from
# glab's published command reference; the tests drive a fake glab that
# records its argv, so what is actually PROVEN here is which flags this file
# emits -- never what the real binary does with them.
#
# ACCOUNT-OVERRIDE LANDING SITE -- RESOLVED: IT STAYS EMPTY, AND HERE IS WHY.
# The landing site the paragraph below describes was left for a later story
# whose central question -- how glab accepts a per-invocation token, and
# whether it can at all -- was deliberately left open at planning time. That
# question has now been answered, and the answer is no. One line, the whole
# reason:
#
#   glab has no per-account token retrieval: there is no `glab auth token` subcommand at all, and its credential store is keyed by HOST alone (`token`, Scope: ScopePerHost), so there is no per-account token for this file to ask glab for.
#
# EVIDENCE (glab source, gitlab-org/cli @ main, read 2026-08-05 -- glab is
# not installed on this machine, this phase's declared verification ceiling,
# so this is read off the source rather than off an observed binary):
#
#   1. internal/commands/auth/ holds exactly `login`, `logout`, `status`,
#      `credentialhelper`, `docker` and `generate`. There is no `token`
#      subcommand, so `gh auth token --user <login> --hostname <host>` --
#      the ONE call _forge_account_override is built on -- has no glab
#      counterpart to be rewritten into.
#   2. There is no per-account model for such a subcommand to address even
#      if it existed. internal/config/schema.go declares the `token` key as
#      `Scope: ScopePerHost` -- one token per instance -- and
#      internal/commands/auth/status/status.go iterates `cfg.Hosts()` and
#      reads `cfg.GetWithSource(instance, "token", true)`: instances, never
#      logins. `glab auth status --show-token --hostname <host>` therefore
#      returns that host's single token, not a named account's, which is why
#      it is not a workaround either.
#   3. The two remaining subcommands are not a back door: `auth generate` is
#      DPoP proof generation and `auth credentialhelper` is a git credential
#      helper. Neither retrieves a token for a named account.
#
# THIS IS NOT THE HOST-DEPENDENCE PROBLEM, which is worth saying because it
# is the first thing a reader will suspect after the
# GH_TOKEN/GH_ENTERPRISE_TOKEN split next door. glab's token environment
# variables are GITLAB_TOKEN, GITLAB_ACCESS_TOKEN and OAUTH_TOKEN
# (internal/config/schema.go), and EnvKeyEquivalence() -- the function that
# resolves them (internal/config/config_mapping.go) -- takes a config KEY and
# no hostname at all. The same three names therefore apply to gitlab.com and
# to every self-managed instance alike, so there is no GHES-style silent
# mis-attribution to guard against here. The blocker is the missing
# retrieval, not the variable name.
#
# SO THIS PATH DEGRADES, DELIBERATELY: every glab invocation below runs as
# the machine's ACTIVE glab session, exactly as if no account had ever been
# recorded for this repository. Nothing here reads the account store and
# nothing here sets, blanks or exports a token variable -- which is also what
# preserves the one selection mechanism glab does have: an operator who
# exported GITLAB_TOKEN before invoking this CLI still picks the acting
# account, because glab reads that variable itself and this file leaves it
# untouched on its way to the child process.
#
# IF GLAB EVER GAINS PER-ACCOUNT RETRIEVAL, the landing site is still here
# and still costs nothing: every glab invocation below is a SINGLE
# `_forge_capture ... -- glab ...` statement on its own line, so a bash
# PREFIX ASSIGNMENT can be added on the line directly above it --
#
#     GITLAB_TOKEN="$gitlab_token_override" \
#       _forge_capture stdout stderr_out rc -- glab mr create -y ... || true
#
# exactly the shape phase 2 used for GH_TOKEN/GH_ENTERPRISE_TOKEN on the gh
# side. `export` stays forbidden for the same reason it is on the gh side --
# a process-wide token changes what every later auth/identity probe in the
# same process reports, starting with _forge_auth_status_gitlab, whose
# `Logged in to <host> as <username>` parse would then report the overridden
# account as the machine's active one and make the very before/after check
# that proves the machine account was left alone unable to detect anything.
#
# SAME-ACCOUNT INVARIANT: the idempotency check that decides created vs
# unchanged, the write itself, and the post-write re-read are all part of ONE
# operation and must run as ONE account. On a private project the creating
# account can see a merge request its reader account cannot, so a check
# performed as a different account would fail against an MR that was just
# successfully created. Degrading to the active session satisfies that
# invariant for free -- one session, every call -- and it is also why a
# future override would have to be put on EVERY glab call in a given
# function, not only on the one that writes.

# Extracts the merge-request/issue URL from a glab write command's stdout.
#
# Deliberately NOT `tail -n1`, which is what the gh side does. gh pr create
# and gh issue create print the bare URL and nothing else; glab's write
# commands print a short human-readable confirmation around theirs, so the
# URL is not reliably the last line. Scanning for the last http(s) token is
# tolerant of that framing without depending on its exact wording.
#
# Prints the empty string when no URL is present -- callers treat that as a
# degraded outcome rather than guessing one.
# Usage: _forge_glab_write_url <captured-stdout>
_forge_glab_write_url() {
  local out="${1:-}" url=""
  url=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'https?://[^[:space:]]+' | tail -n1) || url=""
  printf '%s' "$url"
}

# gitlab adapter for forge-pr-create. Same contract as the github arm in
# _forge_pr_create: shared write envelope, MANDATORY-PRINT degradation,
# non-zero exit on every degraded branch, never retries, never prompts.
#
# IDEMPOTENCY differs from the github arm in ONE way, and the difference is
# forced rather than chosen. gh has `gh pr list --head <branch> --json number`,
# a structural existence probe that answers "no PR" as `[]` at exit 0, so the
# github arm can treat a FAILED lookup as a hard error and refuse to create.
# glab's equivalent read, `glab mr view <branch> -F json`, exits NON-ZERO both
# when the merge request does not exist and when the lookup itself fails, and
# the two are distinguishable only by matching its stderr prose -- exactly the
# fragility forge-pr-view's own not_found detection was made structural to
# avoid. So a failed lookup here falls through to creation instead of
# degrading. That direction is safe on GitLab specifically: GitLab refuses to
# open a second open merge request for the same source/target branch pair, so
# the worst case of guessing wrong is a loud failure from `glab mr create`,
# not a duplicate merge request. Do not "fix" this into a stderr match.
_forge_pr_create_gitlab() {
  local title="$1" base="$2" head="$3" body="$4"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "glab not found -- this merge request was not created automatically."
    return 1
  fi

  # Existing-MR check, as the same account the create below will run as.
  local existing_out="" existing_err="" existing_rc=0 existing_state="" existing_iid=""
  _forge_capture existing_out existing_err existing_rc -- glab mr view "$head" -F json || true

  if [ "$existing_rc" -eq 0 ]; then
    existing_iid=$(printf '%s' "$existing_out" | jq -r '.iid // empty' 2>/dev/null) || existing_iid=""
    if [ -n "$existing_iid" ]; then
      # GitLab's own state vocabulary ("opened"), folded to the contract's
      # through the same _forge_map_state the read verbs use. Only an OPEN
      # merge request blocks; a closed or merged one falls through to
      # creation exactly as it does on the github side, so a reused branch
      # is never blocked forever by a dead MR.
      existing_state=$(_forge_map_state gitlab "$(printf '%s' "$existing_out" | jq -r '.state // empty' 2>/dev/null || true)")
      if [ "$existing_state" = "open" ]; then
        _forge_emit_write_status unchanged "$(_forge_build_write_data \
          "$(printf '%s' "$existing_out" | jq -r '.web_url // empty')" \
          "$existing_iid")"
        return 0
      fi
    fi
  fi

  # WRITE 1 (gitlab). -y FIRST. See this section's header for why its absence
  # would hang rather than fail, and for the prefix-assignment landing site
  # that belongs on the line directly above this one.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- glab mr create -y -t "$title" -d "$body" -s "$head" -b "$base" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: glab mr create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "glab mr create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local mr_url=""
  mr_url=$(_forge_glab_write_url "$stdout")

  if [ -z "$mr_url" ]; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: glab mr create succeeded but its output did not contain a parseable merge request URL." >&2
    _forge_emit_write_status degraded "" "glab mr create succeeded but its output did not contain a parseable merge request URL."
    return 1
  fi

  # PAST THIS POINT THE MERGE REQUEST EXISTS AND ITS URL IS IN HAND -- the
  # identical rule the github arm states at length: never discard $mr_url,
  # never print the create-it-yourself instructions again, never downgrade to
  # degraded (which would force data to null and throw the url away). Only the
  # number is unconfirmed, so it comes back null with a Warning, at exit 0.
  local reread_out="" reread_err="" reread_rc=0 mr_number=""
  _forge_capture reread_out reread_err reread_rc -- glab mr view "$head" -F json || true
  if [ "$reread_rc" -eq 0 ]; then
    mr_number=$(printf '%s' "$reread_out" | jq -r '.iid // empty' 2>/dev/null) || mr_number=""
  fi

  if [ -z "$mr_number" ]; then
    echo "Warning: forge-pr-create: the merge request WAS created at $mr_url, but the post-create glab mr view re-read did not confirm its number -- only the number is unconfirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$mr_url" "")"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$mr_url" "$mr_number")"
}

# gitlab adapter for forge-pr-edit. Same contract as the github arm in
# _forge_pr_edit, including its status word: a successful edit reports
# "unchanged", never "created", because editing mints no new identifier.
# The merge request is a POSITIONAL argument to `glab mr update`, unlike
# `gh pr edit <number>`'s otherwise similar shape.
_forge_pr_edit_gitlab() {
  local number="$1" body="$2"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body"
    _forge_emit_write_status degraded "" "glab not found -- this merge request was not edited automatically."
    return 1
  fi

  # WRITE 2 (gitlab). -y FIRST, same rule, same landing site.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- glab mr update "$number" -y -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body"
    echo "Error: forge-pr-edit: glab mr update exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "glab mr update exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Structured re-read, as the same account that just wrote.
  local reread_out="" reread_err="" reread_rc=0 mr_url="" mr_number=""
  _forge_capture reread_out reread_err reread_rc -- glab mr view "$number" -F json || true
  if [ "$reread_rc" -eq 0 ]; then
    mr_url=$(printf '%s' "$reread_out" | jq -r '.web_url // empty' 2>/dev/null) || mr_url=""
    mr_number=$(printf '%s' "$reread_out" | jq -r '.iid // empty' 2>/dev/null) || mr_number=""
  fi

  if [ -z "$mr_number" ]; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body"
    echo "Error: forge-pr-edit: glab mr update succeeded but the merge request could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "glab mr update succeeded but the merge request could not be re-read afterward."
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$mr_url" "$mr_number")"
}

# gitlab adapter for forge-issue-create. Keeps the github arm's SOFT-FAIL
# contract byte for byte: ALWAYS returns 0, on every branch including
# degraded, so a failed issue never blocks PR creation (open-pr.md:481). The
# caller branches on the envelope's `status` field, never on an exit code.
# Giving the gitlab branch a different exit-code contract from the github one
# would silently reintroduce exactly the coupling this verb exists to prevent.
_forge_issue_create_gitlab() {
  local title="$1" body="$2"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab not found -- this issue was not created automatically."
    return 0
  fi

  # WRITE 3 (gitlab). -y FIRST, same rule, same landing site.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- glab issue create -y -t "$title" -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab issue create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url="" issue_number=""
  issue_url=$(_forge_glab_write_url "$stdout")
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || true)

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab issue create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# ============================================================================
# Gitea write adapters — forge-pr-create, forge-pr-edit, forge-issue-create
# ============================================================================
# The gitea arms of this file's THREE write verbs, kept together in one
# section for the same reason the GitLab section above is: the one rule they
# all obey is stated once, where a reviewer meets it before any code.
#
# THE RULE: EVERY tea WRITE INVOCATION CARRIES AT LEAST ONE FLAG. NO
# EXCEPTIONS.
#
# This is the gitea analogue of the GitLab section's "-y FIRST" rule, and its
# shape is DIFFERENT and worse if hit -- do not go looking for a -y here.
# `tea` has NO -y/--yes/--confirm flag anywhere; inventing one by analogy with
# glab would just be an unknown flag. What tea has instead is
# cmd/pulls/create.go:75-81:
#
#     if ctx.IsInteractiveMode() { … interact.CreatePull(…) }
#
# and modules/context/context.go:55-59:
#
#     // IsInteractiveMode returns true if the command is running in
#     // interactive mode (no flags provided and stdout is a terminal)
#     func (ctx *TeaContext) IsInteractiveMode() bool {
#         return ctx.Command.NumFlags() == 0
#     }
#
# THE DOC COMMENT CLAIMS A TTY CHECK; THE IMPLEMENTATION PERFORMS NONE. The
# sole condition is NumFlags() == 0, so a zero-flag `tea pulls create` enters
# an interactive survey EVEN WITH A NON-TTY STDIN -- a hang, forever, with no
# output explaining why, in an autonomous run with nobody present to answer.
# Every write below passes -t/-d/--head/-b anyway, so the invariant costs
# nothing; it is written down because the cheapest way to break it is an
# innocent-looking refactor that moves a flag behind a conditional.
#
# The invariant is asserted from RECORDED ARGV, never from an exit status: a
# fake tea never prompts, so it exits 0 whether or not a flag was passed and
# an exit-status assertion would pass vacuously.
#
# TEA'S FLAG NAMES ARE NEITHER gh'S NOR glab'S. Read off `gitea/tea` `main`
# source on 2026-08-06 (cmd/flags/issue_pr.go:94-118 for the shared
# create/edit set, cmd/pulls/create.go:26-55 for the pull-specific pair):
#   -t/--title           (same spelling as gh and glab)
#   -d/--description     NOT gh's --body -- the same gotcha glab has
#   --head               LONG FORM ONLY. tea gives it no short alias, and -h
#                        is urfave/cli's help flag, so a "-h" here would print
#                        help instead of naming a branch.
#   -b/--base            NOT glab's --target-branch, and note that glab spells
#                        its OWN -b as --target-branch while tea's -b is
#                        --base -- the short letters agree by coincidence.
# `tea pulls edit` takes the pull request as a POSITIONAL argument and reuses
# IssuePREditFlags (cmd/flags/issue_pr.go:179-202), so -d again.
#
# ⚠️ GH_TOKEN HAZARD -- WHY NO tea CALL BELOW CARRIES A TOKEN PREFIX, AND WHY
# NONE BLANKS ONE EITHER. tea honours GH_TOKEN, not only GITEA_TOKEN
# (modules/context/context_login.go:15-51 reads both and falls back to the
# GitHub one when GITEA_TOKEN is empty). Meanwhile
# _forge_account_override_slots (:2983-2997) deliberately defaults an empty
# slot to the AMBIENT GH_TOKEN. Copying the github arm's prefix-assignment
# shape onto a tea call would therefore hand a GITHUB token to a GITEA
# instance. So no tea invocation below carries a GH_TOKEN= or
# GH_ENTERPRISE_TOKEN= prefix assignment.
#
# Blanking is refused for the OPPOSITE reason: a bare `GITEA_TOKEN=` prefix
# would revoke the one account-selection mechanism a Gitea operator actually
# has, exactly as phase 2's bare TOKEN="" prefix did on the gh side. So this
# path sets nothing and unsets nothing -- an operator-exported GITEA_TOKEN
# reaches tea untouched, and every call runs as the machine's active tea
# session. `export` stays forbidden here for the same process-wide-state
# reason it is forbidden on the gh and glab sides.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY BEHAVIOR BELOW. tea is NOT
# installed on the machine this was written on; that is this phase's declared
# ceiling, not an oversight. Not one invocation here has been observed against
# the real binary. Every flag, subcommand and JSON key was read off
# `gitea/tea` `main` source on 2026-08-06, file and line cited per claim. The
# tests drive a fake tea that records its argv, so what is actually PROVEN is
# WHICH ARGUMENTS THIS FILE EMITS and HOW IT PARSES A FIXTURE -- never what
# real tea does with them.
#
# KNOWN, DELIBERATE DUPLICATE READ PATH -- NOT AN ACCIDENT, AWAITING
# UNIFICATION. _forge_pr_create_gitea's idempotency probe below reads Gitea
# pull requests through its own `tea pulls list --state all -o json` call and
# a local head filter, and does NOT call _forge_pr_view_gitea. That is a
# scheduling fact, not a design preference: _forge_pr_view_gitea lands in the
# SAME wave as this section, so depending on it would make this story
# unbuildable. The result is a second Gitea PR read path in this file --
# recorded here by name so a later reader finds a known debt rather than
# inferring a mistake. It is the same debt the GitLab arm still owes
# (_forge_pr_view_gitlab plus the inline `glab mr view` in
# _forge_pr_create_gitlab), and both should be unified together.
#
# WHY THE PROBE CANNOT ASK THE SERVER, AND WHAT THAT COSTS. `tea pulls list`
# has NO --head / --source-branch filter at all -- its flags are --fields plus
# PRListingFlags (cmd/pulls/list.go:31) = --state (all|open|closed only),
# --page, --limit, --repo, --remote, --login, --output. `gh pr list --head`
# and `glab mr list --source-branch` have no counterpart, so the filter has to
# run locally, and the LIST document it filters differs from the DETAIL
# document in two ways a naive implementation gets wrong:
#
#   (a) EVERY LIST VALUE IS A JSON STRING and every key is snake_cased
#       (modules/print/table.go:175-208 marshals a map[string]string), so
#       `index` arrives as "42", never 42. Comparisons here are therefore
#       string comparisons, and the number reaches _forge_build_write_data as
#       a string it turns into a JSON int with `tonumber`.
#   (b) THE LIST `head` MAY CARRY AN `owner:` PREFIX for a cross-fork pull
#       request (formatPRHead, modules/print/pull.go:83-93), while the DETAIL
#       `head` is a bare ref (cmd/pulls.go:176). So the match cannot be plain
#       equality -- `forkuser:feat-x` must still match the branch `feat-x`.
#
# ONLY AN OPEN PULL REQUEST BLOCKS CREATION. tea's LIST `state` can literally
# be `merged` (formatPRState, modules/print/pull.go:95-100 returns it whenever
# pr.Merged != nil), so a closed or merged pull request on the same branch
# falls through to creation exactly as it does on the github and gitlab arms.
# A reused branch is never blocked forever by a dead pull request.

# Extracts the pull-request/issue URL from a tea write command's stdout.
#
# A SIBLING of _forge_glab_write_url rather than a rename of it, deliberately:
# tea's two write paths have genuinely different framings that this header has
# to state, and renaming the glab one would touch phase 3's shipped gitlab
# arms while sibling stories hold this file open. Duplication over conflict.
#
#   `tea pulls create` ends in print.PullDetails (modules/task/pull_create.go:89)
#   -- a MARKDOWN block whose URL line is appended only when the URL is
#   NON-EMPTY (modules/print/pull.go:76-78), and `--output json` is not
#   consulted on the create path at all. So "created but no parseable URL" is
#   a REAL branch here, not a hypothetical: callers must treat an empty result
#   as a genuine degraded outcome rather than as a parse bug.
#
#   `tea issues create` is friendlier: markdown PLUS a bare `issue.HTMLURL`
#   line (modules/task/issue_create.go:28-30), so a URL is reliably present.
#
# Deliberately NOT `tail -n1` -- both paths wrap the URL in markdown, so the
# URL is not reliably the last LINE. Scanning for the last http(s) TOKEN is
# tolerant of that framing without depending on its exact wording.
#
# Prints the empty string when no URL is present -- callers treat that as a
# degraded outcome rather than guessing one.
# Usage: _forge_tea_write_url <captured-stdout>
_forge_tea_write_url() {
  local out="${1:-}" url=""
  url=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'https?://[^[:space:]]+' | tail -n1) || url=""
  printf '%s' "$url"
}

# gitea adapter for forge-pr-create. Same contract as the github and gitlab
# arms in _forge_pr_create: shared write envelope, MANDATORY-PRINT
# degradation, non-zero exit on every degraded branch, never retries, never
# prompts.
#
# IDEMPOTENCY is structural, like the github arm's and unlike the gitlab
# arm's, but it is built from a LIST-plus-local-filter rather than from a
# server-side head query -- see this section's header for why tea offers no
# such query, for the two ways its LIST document differs from its DETAIL
# document, and for why only an OPEN pull request blocks.
#
# A FAILED LOOKUP FALLS THROUGH TO CREATION rather than degrading, matching
# the gitlab arm. tea has no distinct exit code for "not found" -- main.go:18-30
# prints `Error: %v` and exits 1 for every error alike -- so a failed
# `tea pulls list` is structurally indistinguishable from an empty one, and
# refusing to create on it would strand every run whose listing hiccuped. Do
# not "fix" this into a stderr match; that is exactly the fragility
# forge-pr-view's structural not_found detection exists to avoid.
_forge_pr_create_gitea() {
  local title="$1" base="$2" head="$3" body="$4"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "tea not found -- this pull request was not created automatically."
    return 1
  fi

  # Existing-PR probe, as the same account the create below will run as.
  # --state all, because the local filter -- not the server -- decides which
  # states block, and a merged pull request must be SEEN in order to be
  # deliberately ignored.
  local list_out="" list_err="" list_rc=0 existing_row="" existing_url="" existing_number=""
  _forge_capture list_out list_err list_rc -- tea pulls list --state all -o json || true

  if [ "$list_rc" -eq 0 ]; then
    # The whole local filter, in one jq program:
    #   - tostring on every value, because LIST values are strings already and
    #     a future typed shape must not change the comparison's meaning;
    #   - head matches either exactly or after an `owner:` prefix;
    #   - state must fold to `open` -- `closed` and `merged` fall through.
    existing_row=$(printf '%s' "$list_out" | jq -c --arg h "$head" '
      [ .[]?
        | select(type == "object")
        | select((((.head // "") | tostring) == $h)
                 or (((.head // "") | tostring) | endswith(":" + $h)))
        | select((((.state // "") | tostring) | ascii_downcase) == "open")
      ] | .[0] // empty' 2>/dev/null) || existing_row=""

    if [ -n "$existing_row" ]; then
      existing_url=$(printf '%s' "$existing_row" | jq -r '.url // empty' 2>/dev/null) || existing_url=""
      existing_number=$(printf '%s' "$existing_row" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || existing_number=""
      if [ -n "$existing_number" ]; then
        _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
        return 0
      fi
    fi
  fi

  # WRITE 1 (gitea). Four flags, so NumFlags() is never 0 -- see this
  # section's header for why a zero-flag invocation hangs rather than fails.
  # No token prefix assignment: see the GH_TOKEN hazard in the same header.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea pulls create -t "$title" -d "$body" --head "$head" -b "$base" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: tea pulls create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "tea pulls create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local pr_url=""
  pr_url=$(_forge_tea_write_url "$stdout")

  if [ -z "$pr_url" ]; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: tea pulls create succeeded but its output did not contain a parseable pull request URL." >&2
    _forge_emit_write_status degraded "" "tea pulls create succeeded but its output did not contain a parseable pull request URL."
    return 1
  fi

  # PAST THIS POINT THE PULL REQUEST EXISTS AND ITS URL IS IN HAND -- the same
  # rule the github and gitlab arms state at length: never discard $pr_url,
  # never print the create-it-yourself instructions again, never downgrade to
  # degraded (which would force data to null and throw the created pull
  # request's URL away). Only the number is unconfirmed, so it comes back null
  # with a Warning, at exit 0.
  #
  # The URL's trailing segment is only an ADDRESS for the re-read, never the
  # answer: the number reported below is `index`, read out of the DETAIL
  # document tea returns, so a URL shape this file guessed wrong yields a null
  # number rather than a wrong one.
  local candidate="" reread_out="" reread_err="" reread_rc=0 pr_number=""
  candidate=$(printf '%s' "$pr_url" | grep -oE '[0-9]+$') || candidate=""
  if [ -n "$candidate" ]; then
    _forge_capture reread_out reread_err reread_rc -- tea pulls "$candidate" -o json || true
    if [ "$reread_rc" -eq 0 ]; then
      pr_number=$(printf '%s' "$reread_out" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || pr_number=""
    fi
  fi

  if [ -z "$pr_number" ]; then
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but the post-create tea pulls re-read did not confirm its number -- only the number is unconfirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# gitea adapter for forge-pr-edit. Same contract as the github and gitlab arms
# in _forge_pr_edit, including its status word: a successful edit reports
# "unchanged", never "created", because editing mints no new identifier.
# The pull request is a POSITIONAL argument to `tea pulls edit`, like
# `glab mr update <id>` and unlike `gh pr edit <number>`'s flag-shaped body.
_forge_pr_edit_gitea() {
  local number="$1" body="$2"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body"
    _forge_emit_write_status degraded "" "tea not found -- this pull request was not edited automatically."
    return 1
  fi

  # WRITE 2 (gitea). -d keeps NumFlags() non-zero here; same invariant, same
  # header. No token prefix assignment, same GH_TOKEN hazard.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea pulls edit "$number" -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body"
    echo "Error: forge-pr-edit: tea pulls edit exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "tea pulls edit exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Structured re-read, as the same account that just wrote. The DETAIL shape
  # (`tea pulls <index> -o json`), whose `index` is a real JSON int and whose
  # `url` is pr.HTMLURL -- NOT the LIST shape the create probe filters.
  local reread_out="" reread_err="" reread_rc=0 pr_url="" pr_number=""
  _forge_capture reread_out reread_err reread_rc -- tea pulls "$number" -o json || true
  if [ "$reread_rc" -eq 0 ]; then
    pr_url=$(printf '%s' "$reread_out" | jq -r '.url // empty' 2>/dev/null) || pr_url=""
    pr_number=$(printf '%s' "$reread_out" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || pr_number=""
  fi

  if [ -z "$pr_number" ]; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body"
    echo "Error: forge-pr-edit: tea pulls edit succeeded but the pull request could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "tea pulls edit succeeded but the pull request could not be re-read afterward."
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# gitea adapter for forge-issue-create. Keeps the github and gitlab arms'
# SOFT-FAIL contract byte for byte: ALWAYS returns 0, on every branch
# including degraded, so a failed issue never blocks PR creation. The caller
# branches on the envelope's `status` field, never on an exit code. Giving the
# gitea branch a different exit-code contract would silently reintroduce
# exactly the coupling this verb exists to prevent.
_forge_issue_create_gitea() {
  local title="$1" body="$2"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea not found -- this issue was not created automatically."
    return 0
  fi

  # WRITE 3 (gitea). Two flags, same invariant, same header. No token prefix
  # assignment, same GH_TOKEN hazard.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea issues create -t "$title" -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea issues create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url="" issue_number=""
  issue_url=$(_forge_tea_write_url "$stdout")
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$') || issue_number=""

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea issues create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# Shells `gh pr create --title <t> --base <b> --head <h> --body <b>`,
# capturing stdout as the created PR's URL -- gh pr create has NO --json
# flag (confirmed on this machine, exactly like gh issue create: only a
# plain URL reaches stdout on success). The created PR's `number` is NEVER
# derived by regexing that URL (AC3) -- instead, once creation succeeds,
# this function re-queries story 04's forge-pr-view lookup for the same
# --head branch (a structured re-read) and reads `.pr.number`/`.pr.url`
# from ITS normalized output. forge-pr-view's own --pr flag only accepts a
# branch name or a bare PR number (validated against a fixed regex) -- not
# a URL -- so "feeding the URL back through forge-pr-view" is realized here
# as re-querying by the already-validated --head branch, the one identifier
# both the pre-create idempotency check and the post-create confirmation
# can share; this is what keeps the number's origin a structured field
# read, never a trailing-digit regex on a URL string.
#
# RESULT ENVELOPE: every branch below emits forge-contract.md's shared
# write-verb envelope via _forge_emit_write_status -- {status, data,
# message} with status created | unchanged | degraded, the same shape
# forge-pr-edit and forge-issue-create emit. stdout is therefore NEVER
# silent, not even on a failure branch: a caller that reads stdout learns
# what happened from `status` instead of having to infer it from an empty
# capture. This is an ADDITION to the exit-code contract below, never a
# replacement -- every degraded branch here still returns 1.
#
# IDEMPOTENCY (AC2): before ever shelling out to create anything, looks up
# whether an open PR already exists for $head via forge-pr-view, in-process
# (a direct function call, never a `$AIMI_CLI forge-pr-view` subprocess).
# When an OPEN one is found, reports status "unchanged" with that PR's
# {url, number} and returns 0 WITHOUT attempting a second creation --
# open-pr.md's own "PR already exists for this branch" behavior today,
# informational rather than an error. A retried phase in execute.md's
# per-repository loop is exactly why this matters: a retry must never open
# a duplicate PR for the same branch.
# That check branches over ALL THREE of forge-pr-view's statuses:
# only `found` + a normalized state of `open` short-circuits; `not_found`
# and a found-but-closed/merged PR both proceed to creation; `error` (and
# any status this code does not recognize) is a hard failure that NEVER
# reaches `gh pr create`.
#
# MANDATORY-PRINT degrade mode: see this section's header comment above for
# the full statement of why this differs from forge-issue-create's soft-
# fail contract. Every failure path that runs BEFORE `gh pr create` has
# returned a url -- unsupported forge, missing gh, the existing-PR lookup
# erroring, the create call itself failing, an unparseable success response
# -- prints the manual create-it-yourself instructions via
# _forge_pr_write_print_manual, emits a status "degraded" envelope carrying
# the same reason text, and returns 1. Once a url IS in hand the manual
# fallback is never printed again AND the outcome is never downgraded to
# degraded: a post-create re-read failure keeps that url, reports status
# "created" with data {url, number: null} at exit 0, and warns that only
# the number is unconfirmed. Reporting that branch as degraded would force
# `data` to null and throw the created PR's url away -- the exact defect
# the "PAST THIS POINT" comment below exists to prevent. Never retries,
# never prompts interactively.
_forge_pr_create() {
  local title="$1" base="$2" head="$3" body="$4"
  local forge=""
  _detect_forge_type forge

  # Routing, not a github/not-github gate. The `|| gl_rc=$?` capture is
  # mandatory under this file's `set -e`: the gitlab arm returns 1 on every
  # degraded branch by contract, and an uncaptured non-zero return from a
  # plain statement would abort the whole CLI before the envelope reached
  # stdout.
  case "$forge" in
    github) ;;
    gitlab)
      local gl_rc=0
      _forge_pr_create_gitlab "$title" "$base" "$head" "$body" || gl_rc=$?
      return "$gl_rc"
      ;;
    gitea)
      local gt_rc=0
      _forge_pr_create_gitea "$title" "$base" "$head" "$body" || gt_rc=$?
      return "$gt_rc"
      ;;
    *)
      _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
      _forge_emit_write_status degraded "" "forge-pr-create: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 1
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "gh not found -- this pull request was not created automatically."
    return 1
  fi

  # This repository's remembered account, resolved ONCE for all three gh-facing
  # steps below (the idempotency check, the create itself, the post-create
  # re-read) rather than re-derived at each one. Both slots are named at every
  # site and at most one is ever non-empty; the empty case is the opt-out and
  # needs no branch. Resolved AFTER the gh gate above so a machine with no gh
  # gets one explanation, not two. See the ROUTING RULE block above the
  # forge-auth-status section -- export is forbidden, prefix assignment only.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # Existing-PR check. `state` rides along with url/number precisely because
  # this branch has to tell an OPEN PR (which blocks creation) apart from a
  # closed/merged one (which must not) -- `gh pr view <branch>` is NOT
  # state-filtered, so a branch reused after its prior PR was merged still
  # resolves to that stale PR here.
  # Routed: this lookup is part of the create operation, so it must run as the
  # same account the create will (a private repo can let the creating account
  # see a PR its reader account cannot).
  local existing="" existing_rc=0 existing_status existing_state existing_message
  existing=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$head" --include url,number,state) || existing_rc=$?
  if [ "$existing_rc" -ne 0 ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: forge-pr-view lookup failed while checking for an existing PR (exit $existing_rc)." >&2
    _forge_emit_write_status degraded "" "forge-pr-create: forge-pr-view lookup failed while checking for an existing PR (exit $existing_rc)."
    return 1
  fi

  # Branch over ALL THREE statuses forge-pr-view can return, never just
  # found. forge-pr-view exists specifically so "no PR exists" is
  # distinguishable from "the lookup broke", and it reports the latter as
  # status:"error" INSIDE its envelope at exit 0 -- so the $existing_rc
  # guard above cannot see it. A check that only tested for "found" let
  # error fall through to `gh pr create` and opened a duplicate PR for a
  # branch whose real PR the tool simply could not read (an expired token,
  # a network blip). Creation happens on not_found alone -- plus the
  # explicitly-inspected closed/merged case below.
  existing_status=$(printf '%s' "$existing" | jq -r '.status')
  case "$existing_status" in
    found)
      # Only an OPEN PR blocks -- matching cmd_help's own "existing open PR"
      # wording. A closed or merged PR on this branch falls through to
      # creation exactly like not_found, so a reused branch gets a fresh
      # pull request instead of being blocked forever by a dead one.
      existing_state=$(printf '%s' "$existing" | jq -r '.pr.state // empty')
      if [ "$existing_state" = "open" ]; then
        # "unchanged", not a `created:false` boolean: no new PR number was
        # minted, which is exactly what forge-contract.md's Write-Verb
        # Status Convention names that outcome -- and the same word every
        # successful forge-pr-edit call reports.
        _forge_emit_write_status unchanged "$(_forge_build_write_data \
          "$(printf '%s' "$existing" | jq -r '.pr.url // empty')" \
          "$(printf '%s' "$existing" | jq -r '.pr.number // empty')")"
        return 0
      fi
      ;;
    not_found)
      ;;
    error|*)
      # `error` is named explicitly; `*` makes any future status value fail
      # the same closed way. Neither is a defensible reason to create a PR:
      # a status this code does not understand must never be read as
      # permission to open one. Unreachable in practice today --
      # _forge_pr_view_emit rejects a fourth status before it ever reaches
      # this caller -- but the fall-through it replaces is exactly the class
      # of defect this branch exists to prevent.
      existing_message=$(printf '%s' "$existing" | jq -r '.message // empty')
      _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
      echo "Error: forge-pr-create: forge-pr-view reported an error while checking for an existing PR on $head: ${existing_message:-unknown error}" >&2
      _forge_emit_write_status degraded "" "forge-pr-create: forge-pr-view reported an error while checking for an existing PR on $head: ${existing_message:-unknown error}"
      return 1
      ;;
  esac

  # WRITE 1. The prefix assignment is on the _forge_capture call itself, so the
  # value is set for the duration of that one function call, exported into the
  # `gh` grandchild it spawns, and unset again the moment it returns --
  # _forge_capture's argv-only signature is untouched and the token never
  # becomes an argv element. `env GH_TOKEN=... gh ...` is forbidden for exactly
  # that reason: env(1)'s own argv would carry it into the process table.
  local stdout rc=0 stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh pr create --title "$title" --base "$base" --head "$head" --body "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: gh pr create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "gh pr create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local pr_url
  pr_url=$(printf '%s' "$stdout" | tail -n1 | tr -d '\r')

  if [ -z "$pr_url" ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: gh pr create succeeded but its output did not contain a parseable PR URL." >&2
    _forge_emit_write_status degraded "" "gh pr create succeeded but its output did not contain a parseable PR URL."
    return 1
  fi

  # Structured re-read (AC3) -- never a regex on $pr_url.
  #
  # PAST THIS POINT THE PR EXISTS AND ITS URL IS IN HAND, so neither failure
  # branch below may discard $pr_url, report failure, or print the manual
  # create-it-yourself instructions: a caller following those instructions
  # would open a SECOND pull request for a branch that already has one, and
  # execute.md's per-repository loop would report a successful creation as a
  # failure. Only the number is unconfirmed, so it comes back null with a
  # Warning (not an Error) naming the url, at exit 0.
  #
  # That is also why both branches below stay status "created" rather than
  # "degraded": a new PR number genuinely WAS minted, and `degraded` forces
  # `data` to null by design (forge-contract.md's Write-Verb Status
  # Convention), which would throw the very url this comment exists to
  # protect straight back away.
  # Routed for the same reason the idempotency check above is, and here the
  # consequence is concrete: on a private repository this re-read performed as
  # the machine account would fail against a PR the overridden account has just
  # successfully created.
  local reread="" reread_rc=0 reread_status reread_message pr_number
  reread=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$head" --include url,number) || reread_rc=$?
  if [ "$reread_rc" -ne 0 ]; then
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but the post-create forge-pr-view re-read failed (exit $reread_rc) -- only its number could not be confirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi
  reread_status=$(printf '%s' "$reread" | jq -r '.status')
  if [ "$reread_status" != "found" ]; then
    reread_message=$(printf '%s' "$reread" | jq -r '.message // empty')
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but it could not be re-read afterward (forge-pr-view status: $reread_status${reread_message:+ -- $reread_message}) -- only its number could not be confirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi
  pr_number=$(printf '%s' "$reread" | jq -r '.pr.number // empty')

  _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# Public wrapper: parses --title/--base/--head/--body/--project (deliberately
# no --token or similarly credential-shaped flag -- see this section's
# header comment and forge-contract.md's Credential/Identity Model),
# applies the three standard guards used by cmd_detect_parent_branch/
# cmd_resolve_base_branch (project cd, git-repository check, branch-name
# validation against the existing ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ pattern for
# BOTH --base and --head, before either is ever interpolated into a git/gh
# invocation), then delegates exactly once to _forge_pr_create.
cmd_forge_pr_create() {
  check_jq

  local title="" base="" head="" body="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title)   shift; title="${1:-}" ;;
      --base)    shift; base="${1:-}" ;;
      --head)    shift; head="${1:-}" ;;
      --body)    shift; body="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-create: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$title" ] || [ -z "$base" ] || [ -z "$head" ]; then
    echo "Usage: aimi-cli.sh forge-pr-create --title <t> --base <branch> --head <branch> [--body <text>] [--project <path>]" >&2
    exit 1
  fi

  # Validate every branch name BEFORE it is ever interpolated into a git/gh
  # invocation (plugins/aimi-engineering/CLAUDE.md Security Requirements).
  if ! [[ "$base" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-create: invalid --base value: $base" >&2
    exit 1
  fi
  if ! [[ "$head" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-create: invalid --head value: $head" >&2
    exit 1
  fi

  _forge_pr_create "$title" "$base" "$head" "$body"
}

# Shells `gh pr edit <number> --body <b>`, then re-reads the edited PR via
# story 04's forge-pr-view lookup (in-process, keyed on the same numeric
# identifier the caller supplied) to confirm and report {url, number} under
# the write envelope's `data` key -- the same structured-field discipline
# _forge_pr_create applies, and now genuinely the same JSON shape, so a
# caller really can treat both verbs' output identically (AC4). It did not
# before: this function used to return a bare {url, number} with no status
# field at all while forge-pr-create returned {url, number, created}, so
# the two shapes never matched despite the comment here claiming they did.
#
# A successful edit reports status "unchanged", never "created": editing a
# PR mutates a number that already existed and mints no new identifier,
# which is precisely what forge-contract.md's Write-Verb Status Convention
# means by that word. The PR's BODY did change -- "unchanged" is about the
# resource identifier, not about the content.
#
# MANDATORY-PRINT degrade mode: identical contract to _forge_pr_create --
# see this section's header comment. Every failure branch also emits a
# status "degraded" envelope on stdout carrying the same reason its stderr
# text states. Never retries, never prompts interactively, exits non-zero
# on every failure path.
_forge_pr_edit() {
  local number="$1" body="$2"
  local forge=""
  _detect_forge_type forge

  # Same routing shape and the same `set -e` capture rule as
  # _forge_pr_create above.
  case "$forge" in
    github) ;;
    gitlab)
      local gl_rc=0
      _forge_pr_edit_gitlab "$number" "$body" || gl_rc=$?
      return "$gl_rc"
      ;;
    gitea)
      local gt_rc=0
      _forge_pr_edit_gitea "$number" "$body" || gt_rc=$?
      return "$gt_rc"
      ;;
    *)
      _forge_pr_write_print_manual edit "$forge" "" "$number" "$body"
      _forge_emit_write_status degraded "" "forge-pr-edit: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 1
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body"
    _forge_emit_write_status degraded "" "gh not found -- this pull request was not edited automatically."
    return 1
  fi

  # Resolved ONCE for both the edit and its post-edit re-read -- see
  # _forge_pr_create's own resolution and the ROUTING RULE block above the
  # forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # This call alone discarded gh's stdout to /dev/null rather than capturing
  # it. It now lands in a local nothing reads, which is behaviourally
  # identical -- neither form ever printed or inspected it.
  #
  # WRITE 2. Identical prefix-assignment shape to WRITE 1: on the
  # _forge_capture call, never inside its argv, never via `env`.
  local stdout rc=0 stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh pr edit "$number" --body "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body"
    echo "Error: forge-pr-edit: gh pr edit exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "gh pr edit exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Routed: part of the same logical edit, so it reads as the account that
  # just wrote.
  local reread="" reread_rc=0 reread_status pr_url pr_number
  reread=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$number" --include url,number) || reread_rc=$?
  if [ "$reread_rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body"
    echo "Error: forge-pr-edit: gh pr edit succeeded but the post-edit forge-pr-view re-read failed (exit $reread_rc)." >&2
    _forge_emit_write_status degraded "" "gh pr edit succeeded but the post-edit forge-pr-view re-read failed (exit $reread_rc)."
    return 1
  fi
  reread_status=$(printf '%s' "$reread" | jq -r '.status')
  if [ "$reread_status" != "found" ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body"
    echo "Error: forge-pr-edit: gh pr edit succeeded but the PR could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "gh pr edit succeeded but the PR could not be re-read afterward."
    return 1
  fi
  pr_url=$(printf '%s' "$reread" | jq -r '.pr.url // empty')
  pr_number=$(printf '%s' "$reread" | jq -r '.pr.number // empty')

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# Public wrapper: parses --number/--body/--project (no --token or similarly
# credential-shaped flag -- see this section's header comment), applies the
# same three standard guards as cmd_forge_pr_create (project cd, git-
# repository check, identifier validation before shelling out) -- --number
# is validated as numeric-only (^[0-9]+$) rather than the branch-name
# pattern, matching cmd_forge_issue_view's own numeric-identifier guard --
# then delegates exactly once to _forge_pr_edit.
cmd_forge_pr_edit() {
  check_jq

  local number="" body="" project_dir="" body_provided=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)  shift; number="${1:-}" ;;
      # body_provided tracks whether the FLAG was seen, deliberately not
      # whether its value is non-empty: `gh pr edit N --body ""` blanks a
      # description, so "flag omitted entirely" (a caller that forgot it,
      # which must be refused) and "--body ''" (a deliberate clear, which
      # must keep working) have to stay distinguishable. Checking $body for
      # emptiness would collapse them back together.
      --body)    shift; body="${1:-}"; body_provided=1 ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-edit: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$number" ] || [ -z "$body_provided" ]; then
    echo "Usage: aimi-cli.sh forge-pr-edit --number <n> --body <text> [--project <path>]" >&2
    exit 1
  fi

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-pr-edit: --number must be a positive integer (got: $number)" >&2
    exit 1
  fi

  _forge_pr_edit "$number" "$body"
}

# ============================================================================
# Forge Issue Verbs — forge-issue-view, forge-issue-create (US-006)
# ============================================================================
# The first forge-* verbs in this phase to actually shell out to a forge
# CLI. Built entirely on US-002's shared builders/degradation gate
# (_forge_build_issue_json, _forge_emit_status, _forge_bin_check) and
# US-001's detect-forge -- neither is re-derived here.
#
# INVARIANT, stated here and again on cmd_forge_issue_create below because
# it is the whole reason this pair exists: a failed or degraded issue
# creation must NEVER be treated by a caller as a reason to block PR
# creation. open-pr.md:481 already documents this in prose ("a warning is
# logged but PR creation is NOT affected -- the backend spec still lives in
# the PR body"); forge-issue-create's JSON `status` field (never its exit
# code, which stays 0 on every syntactically valid call -- see below) is
# what lets a future caller preserve that behavior once it migrates off a
# raw `gh issue create` shell-out.
#
# GitHub was the only adapter in phase 1. Phase 3 added GitLab and phase 4
# added Gitea, to the READ verb (forge-issue-view -> `glab issue view <n> -F
# json` / `tea issues <n> -o json`) AND to forge-issue-create itself
# (_forge_issue_create_gitlab / _forge_issue_create_gitea), so this verb is no
# longer GitHub-only. A detected forge with no adapter still degrades exactly
# like a missing CLI binary rather than attempting a call that could only
# fail.

# Forge-native issue/PR state strings, normalized per forge-contract.md's
# "State Mapping" table. Case-folded first because GitHub's gh CLI returns
# OPEN/CLOSED/MERGED in uppercase while GitLab/Gitea's APIs are lowercase.
# Once case-folded, every cell in that table already agrees across all
# three forges EXCEPT GitLab's "opened", which has no "open"-spelled
# sibling anywhere else -- that is the one and only translation this
# function performs. GitLab's "locked" has no GitHub or Gitea/Forgejo
# equivalent and passes through unchanged rather than being collapsed into
# "merged" (collapsing would silently discard a real GitLab-only signal).
# An unrecognized forge, or a raw value this table does not name, passes
# through case-folded and otherwise untouched -- this function normalizes
# spelling, it never invents a value the source data did not provide.
# Usage: _forge_map_state <forge: github|gitlab|gitea> <raw-state>
_forge_map_state() {
  local forge="$1" raw
  raw=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')

  if [ "$forge" = "gitlab" ] && [ "$raw" = "opened" ]; then
    printf 'open'
    return 0
  fi

  printf '%s' "$raw"
}

# Extracts the trailing issue number from a GitHub issue URL
# (https://github.com/<owner>/<repo>/issues/<n>, optionally followed by a
# path/query/fragment). Prints empty on a non-matching URL rather than
# guessing -- cmd_forge_issue_view treats an empty result as a caller-input
# error, never a silent zero.
_forge_extract_issue_number_from_url() {
  local url="$1"
  if [[ "$url" =~ /issues/([0-9]+)([/?#].*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Shells `gh issue view <n> --json number,title,body,labels,state,url,
# comments`. `comments` is requested in addition to the field list this
# story's own prose quotes, specifically so unsupported_fields comes back
# [] on GitHub: forge-contract.md's issue object treats comments as the
# ONE capability-gated field, and GitHub can supply it cheaply (a comment
# COUNT, derived here from the length of gh's own comments array) -- only
# GitLab's noisier discussion model and tea's uncertain counting semantics
# keep it capability-gated at all. `labels` is not in forge-contract.md's
# issue field table today -- GitHub/GitLab/Gitea all expose it as a
# portable-core concept, so it rides alongside _forge_build_issue_json's
# output via a jq merge rather than waiting on a contract-doc update this
# story does not own.
#
# QUIET degrade mode throughout (forge-contract.md's Degradation
# Contract): a missing gh, an unauthenticated session, and any other gh
# failure all resolve to status "error" with NO stderr output --
# validate-bug.md's free-text-description fallback (the caller this verb
# was built for) must not gain a spurious warning it does not have today.
#
# Not-found is a query result, never a verb failure (mirrors split-detect
# and verify-creates): gh conflates "no such issue" and "tool is broken"
# into the same non-zero exit, so gh's own stderr text is pattern-matched
# here to tell the two apart BEFORE calling _forge_emit_status -- the same
# discipline roadmap.py's verify_creates_one already applies to git's ambiguous exit
# codes. (The AC's "found (boolean)" language maps onto this three-way
# `status` field: status=="found" is the found:true case, status==
# "not_found" is the found:false case -- forge-contract.md's Three-Way
# Status Convention is the single arbiter of this vocabulary and already
# names forge-issue-view as one of its consumers, so no second/variant
# "found" field is introduced alongside it.)
#
# Always returns 0 -- found/not_found/error are three data outcomes, not
# three exit codes. cmd_forge_issue_view (the public wrapper) is the only
# layer that can exit non-zero, and only for a caller-side usage error.
_forge_issue_view() {
  local number="$1"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) purely
  # so the generic-failure branch below can hand it to the shared classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      # Names glab, never gh -- the phase contract's fourth success criterion.
      _forge_emit_status error "" "glab not found -- this issue lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_issue_view_gitlab "$number" "$host"
    return 0
  fi

  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      # Names tea, never gh -- the phase contract's fourth success criterion.
      _forge_emit_status error "" "tea not found -- this issue lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_issue_view_gitea "$number" "$host"
    return 0
  fi

  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-issue-view: no adapter for forge \"$forge\" yet -- github, gitlab and gitea are the adapters available today." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this issue lookup did not run automatically." cli_missing
    return 0
  fi

  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- gh issue view "$number" --json number,title,body,labels,state,url,comments || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json comments_count data
    num=$(printf '%s' "$stdout" | jq -r '.number // empty')
    title_val=$(printf '%s' "$stdout" | jq -r '.title // ""')
    body_val=$(printf '%s' "$stdout" | jq -r '.body // ""')
    url_val=$(printf '%s' "$stdout" | jq -r '.url // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r '.state // ""')
    state_norm=$(_forge_map_state "$forge" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[].name]')
    comments_count=$(printf '%s' "$stdout" | jq -c '(.comments // []) | length')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --comments "$comments_count" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  if printf '%s' "$stderr_out" | grep -qi "Could not resolve to an issue or pull request"; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found stderr match above already failed, so
  # gh genuinely broke. gh's presence was confirmed by the _forge_bin_check
  # gate above, so the classifier only has to separate not_authenticated
  # from cli_failed -- cli_missing is already ruled out.
  local reason
  reason=$(_forge_classify_gh_failure_reason "$host")
  _forge_emit_status error "" "gh issue view exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# gitlab adapter for forge-issue-view. Same three-way found/not_found/error
# envelope (_forge_emit_status), same shared issue builder
# (_forge_build_issue_json), same quiet degrade posture -- only the CLI, the
# key vocabulary and the not-found signal differ.
#
# `-F json`, NOT a gh-style `--json <field-list>`. `glab issue view` offers
# `-F, --output string  Format output as: text, json` plus `--jq string`
# and no field selector at all (docs/source/issue/view.md), and its JSON path
# marshals go-gitlab's *gitlab.Issue whole. So the call asks for the whole
# document and this function picks keys out of it.
#
# THE KEYS COME FROM _forge_map_pr_field_gitlab, NOT FROM A SECOND HAND-
# WRITTEN TABLE HERE. GitLab spells the five portable-core contract fields
# identically on an issue and on a merge request -- `iid`, `web_url`,
# `title`, `description`, `state` are struct tags on BOTH *gitlab.Issue and
# *gitlab.MergeRequest -- so reusing that one table is what keeps this call
# site from hard-coding GitLab key names of its own. That coincidence is not
# left to trust: test-aimi-cli.sh asserts each of the five mapper answers
# against a realistic `glab issue view -F json` document, so a future edit
# that made the MR table diverge fails there rather than silently here. The
# MR-only fields (headRefName/baseRefName/isDraft/mergeable/files) are simply
# never asked for.
#
# `comments` IS DELIBERATELY NOT SUPPLIED, so it comes back null AND named in
# unsupported_fields. forge-contract.md makes `comments` the issue object's
# one capability-gated field precisely because GitLab's discussion model does
# not answer the same question GitHub's flat comment array does; a count
# invented from a differently-shaped resource would be a guess. Reporting it
# absent is the contract's own mechanism for exactly this.
#
# `labels` rides alongside the builder's output via a jq merge, the same way
# the github arm adds it. GitLab returns labels as an array of plain STRINGS
# (go-gitlab `Labels []string json:"labels"`) where GitHub returns objects
# with a `.name`; the expression below accepts either shape rather than
# assuming one, so a label list is never silently dropped.
#
# VERIFICATION CEILING: glab is not installed on the machine this was written
# on. Same declared ceiling as _forge_map_pr_field_gitlab's header.
_forge_issue_view_gitlab() {
  local number="$1" host="${2:-}"
  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- glab issue view "$number" -F json || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json data
    num=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab number)" '.[$k] // empty')
    title_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab title)" '.[$k] // ""')
    body_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab body)" '.[$k] // ""')
    url_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab url)" '.[$k] // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab state)" '.[$k] // ""')
    # Key mapping and VALUE normalization are separate jobs: this is where
    # GitLab's "opened" becomes the contract's "open".
    state_norm=$(_forge_map_state "gitlab" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[] | if type == "object" then .name else . end]')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  # not_found is a query RESULT, never a verb failure -- the same distinction
  # the github arm draws. glab surfaces a missing issue as the API's own 404.
  if printf '%s' "$stderr_out" | grep -qiE '404|not found'; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found match above already failed, so glab
  # genuinely broke. glab's presence was confirmed by the caller's own
  # _forge_bin_check gate, so cli_missing is already ruled out and only
  # not_authenticated vs cli_failed remains. Determined STRUCTURALLY, by
  # asking _forge_auth_status_gitlab whether there is a session at all --
  # never by pattern-matching glab's failure wording, which is translatable
  # and rewordable. Anything short of a definite "authenticated: false"
  # resolves to cli_failed, the safe direction for an already-known failure.
  local reason="cli_failed" auth_json authenticated
  auth_json=$(_forge_auth_status_gitlab "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""
  if [ "$authenticated" = "false" ]; then
    reason="not_authenticated"
  fi
  _forge_emit_status error "" "glab issue view exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# gitea adapter for forge-issue-view. Same three-way found/not_found/error
# envelope (_forge_emit_status), same shared issue builder
# (_forge_build_issue_json), same quiet degrade posture -- only the CLI, the
# key vocabulary and the not-found signal differ.
#
# `tea issues <index> -o json` is the DETAIL form (cmd/issues.go's `issueData`
# struct: id, index, title, state, created, labels[], user, body,
# assignees[], url, closedAt, comments[]). No `-f`, and no gh-style
# `--json <field-list>`: tea's `-f` selector lives on the LIST path only, and
# the detail path emits a fixed projection.
#
# THE KEYS COME FROM _forge_map_pr_field_gitea, NOT FROM A SECOND HAND-
# WRITTEN TABLE HERE -- the same reuse _forge_issue_view_gitlab makes, and
# for the same reason. Gitea spells the five portable-core contract fields
# identically on an issue and on a pull request: `index`, `url`, `title`,
# `body` and `state` are struct fields on BOTH `pullData` and `issueData`.
# The PR-only fields (headRefName/baseRefName/isDraft/mergeable/files) are
# simply never asked for.
#
# `comments` IS DELIBERATELY NOT SUPPLIED, so it comes back null AND named in
# unsupported_fields. This is not caution about tea's counting semantics
# alone -- it is a data fact: `issueData.Comments` is an ARRAY that is
# populated ONLY when `--comments` is passed (cmd/issues.go:148-154), and is
# an EMPTY ARRAY otherwise. Deriving a count from its length here would
# report `comments: 0` for every issue in existence. A wrong count is worse
# than a declared absence, and the contract's unsupported_fields array is the
# mechanism for exactly this.
#
# `labels` rides alongside the builder's output via a jq merge, the same way
# the github and gitlab arms add it, and through the same either-shape
# expression: tea's own printer can hand back plain strings while the API
# object carries `{name}`, so accepting either is what keeps a label list
# from being silently dropped.
#
# THERE IS DELIBERATELY NO STRUCTURAL not_found PROBE HERE, unlike
# _forge_pr_view_gitea, and this is a recorded decision rather than an
# oversight so it is not later "improved" into a scan: `tea issues list` is
# PAGINATED (--page/--limit) and has no index filter at all, so a local scan
# of one page could report a real issue as missing. A FALSE not_found is the
# one outcome that must never be invented, and a paginated scan can invent
# it. So absence is claimed only on a POSITIVE 404/not-found stderr match,
# and every other failure resolves to error -- falling through in the SAFE
# direction, which is the same rule the pr-view arm applies to an
# unparseable probe.
#
# NO CREDENTIAL IS BOUND ON ANY INVOCATION HERE -- see
# _forge_auth_status_gitea's header for why a GH_TOKEN prefix assignment on a
# `tea` call would be a real leak rather than a hypothetical one.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. The tests prove WHICH ARGV this function emits and
# HOW it parses a fixture -- never what real `tea` does with them.
_forge_issue_view_gitea() {
  local number="$1" host="${2:-}"
  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- tea issues "$number" -o json || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json data
    num=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea number)" '.[$k] // empty')
    title_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea title)" '.[$k] // ""')
    body_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea body)" '.[$k] // ""')
    url_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea url)" '.[$k] // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea state)" '.[$k] // ""')
    # Key mapping and VALUE normalization are separate jobs. There is no
    # hasMerged derivation on this path and there must not be: an ISSUE is
    # never merged, so _forge_map_state's plain case-fold is the whole job.
    state_norm=$(_forge_map_state "gitea" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[] | if type == "object" then .name else . end]')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  # not_found is a query RESULT, never a verb failure -- the same distinction
  # the github and gitlab arms draw. A POSITIVE match is required; see the
  # header for why nothing weaker may claim absence on this path.
  if printf '%s' "$stderr_out" | grep -qiE '404|not found'; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found match above already failed, so tea
  # genuinely broke. tea's presence was confirmed by the caller's own
  # _forge_bin_check gate, so cli_missing is already ruled out and only
  # not_authenticated vs cli_failed remains. Determined STRUCTURALLY, by
  # asking _forge_auth_status_gitea whether a login entry for this host
  # exists at all -- never by pattern-matching tea's failure wording, which
  # is translatable and rewordable. That adapter returns NON-ZERO when it
  # could not read the login list, which lands here as an empty $auth_json
  # and therefore cli_failed: anything short of a definite
  # "authenticated: false" resolves to cli_failed, the safe direction for an
  # already-known failure.
  local reason="cli_failed" auth_json authenticated
  auth_json=$(_forge_auth_status_gitea "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""
  if [ "$authenticated" = "false" ]; then
    reason="not_authenticated"
  fi
  _forge_emit_status error "" "tea issues exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# Public wrapper: parses --number/--url/--project, validates the numeric
# identifier BEFORE it is ever interpolated into a gh command (mirroring
# the branchName-validation posture in plugins/aimi-engineering/CLAUDE.md's
# Security Requirements), confirms the git-repository guard the same way
# detect-forge/detect-parent-branch/detect-default-branch already do (gh
# infers which repo to query from cwd's remote; there is no --repo flag
# here), then delegates exactly once to _forge_issue_view.
#
# Routing note for the later validate-bug.md migration (recorded here so
# that story does not have to re-derive it): validate-bug.md's plain-
# issue-number branch and its GitHub-issue-URL branch both route to THIS
# verb; its PR-URL branch (validate-bug.md:39) routes to forge-pr-view
# instead, even though it requests an identical field set, because it
# reads a pull request, not an issue.
cmd_forge_issue_view() {
  check_jq

  local number="" url="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)  shift; number="${1:-}" ;;
      --url)     shift; url="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-issue-view: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$number" ] && [ -n "$url" ]; then
    number=$(_forge_extract_issue_number_from_url "$url")
    if [ -z "$number" ]; then
      echo "Error: forge-issue-view: could not extract an issue number from --url: $url" >&2
      exit 1
    fi
  fi

  if [ -z "$number" ]; then
    echo "Error: forge-issue-view: --number <n> or --url <issue-url> is required" >&2
    exit 1
  fi

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-issue-view: --number must be a positive integer (got: $number)" >&2
    exit 1
  fi

  _forge_issue_view "$number"
}

# Prints the MANDATORY manual-fallback instruction (forge-contract.md's
# Degradation Contract, mandatory mode) for every forge-issue-create
# failure path -- missing gh, unauthenticated session, or the create call
# itself failing all funnel through this one function so the instruction
# is worded identically regardless of WHY automatic creation did not
# happen. Always stderr, never stdout, so a caller consuming this verb's
# JSON result on stdout never has to filter prose out of its own data.
_forge_issue_create_print_manual() {
  local title="$1" body="$2" forge="$3"
  {
    echo "Warning: could not create this $forge issue automatically -- create it yourself with:"
    echo "  Title: $title"
    echo "  Body:"
    printf '%s\n' "$body" | sed 's/^/    /'
  } >&2
}

# Shells `gh issue create --title <t> --body <b>`, capturing stdout as the
# created issue's URL -- gh issue create has NO --json flag (confirmed:
# unlike gh issue view/gh pr view, only a plain URL reaches stdout on
# success) -- and deriving the issue number from that URL itself, the same
# grep -oE '[0-9]+$' open-pr.md:464 does today, centralized and tested here
# exactly once so open-pr.md's later migration (story 08) can drop its own
# copy.
#
# MANDATORY-PRINT degrade mode (forge-contract.md's Degradation Contract):
# unlike forge-issue-view's quiet read, this write verb has no fallback
# path of its own, so every failure -- missing gh, unauthenticated
# session, the create call itself failing (permissions denied, issues
# disabled, rate limit), or an unparseable success response -- prints the
# manual "create this yourself" instruction via
# _forge_issue_create_print_manual.
#
# RESULT ENVELOPE: this verb SHARES aimi-cli.sh's one write-verb envelope
# with forge-pr-create and forge-pr-edit -- forge-contract.md's Write-Verb
# Status Convention, built here by the same _forge_emit_write_status
# function those two call, with url and number nested under `data` exactly
# as they are there. It used to maintain a deliberately separate two-value
# (created|degraded) vocabulary with flat sibling url/number keys; there is
# no longer any reason for a caller to learn a second shape to read this
# verb's answer.
#
# What still distinguishes this envelope from forge-contract.md's READ-side
# found/not_found/error trio is unchanged and correct: a write genuinely has
# no "not found" outcome, since nothing was looked up. That is the reason
# the write side has its own three values, not a reason for each write verb
# to have its own.
#
# CONTRACT INVARIANT: printing that instruction is NEVER a hard failure.
# This function always returns 0 -- on EVERY branch, degraded included; its
# JSON result's `status` field is what a caller branches on -- see the
# section header above and cmd_forge_issue_create below for the full
# statement of why (open-pr.md:481's existing soft-fail behavior must
# survive unchanged). Sharing the envelope with forge-pr-create/
# forge-pr-edit deliberately does NOT share their exit-code contract: those
# two exit non-zero on a degraded outcome, this one never does.
_forge_issue_create() {
  local title="$1" body="$2"
  local forge=""
  _detect_forge_type forge

  # Same routing shape as the two pr verbs, with this verb's OWN exit-code
  # contract preserved: the gitlab arm, like everything else here, always
  # returns 0 and reports the outcome in the envelope's `status` field.
  case "$forge" in
    github) ;;
    gitlab)
      _forge_issue_create_gitlab "$title" "$body"
      return 0
      ;;
    gitea)
      _forge_issue_create_gitea "$title" "$body"
      return 0
      ;;
    *)
      _forge_issue_create_print_manual "$title" "$body" "$forge"
      _forge_emit_write_status degraded "" "forge-issue-create: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 0
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh not found -- this issue was not created automatically."
    return 0
  fi

  # Resolved once, then applied to the one gh call this verb makes -- this path
  # has no in-operation read (the issue number is parsed from the URL gh
  # itself printed, never re-queried). See the ROUTING RULE block above the
  # forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # WRITE 3. Identical prefix-assignment shape to WRITE 1 and WRITE 2.
  local stdout rc=0
  local stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh issue create --title "$title" --body "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh issue create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url issue_number
  issue_url=$(printf '%s' "$stdout" | tail -n1 | tr -d '\r')
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || true)

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh issue create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# Public wrapper: parses --title/--body/--project (deliberately no --token
# or similarly credential-shaped flag -- see forge-contract.md's
# Credential/Identity Model), confirms the git-repository guard, then
# delegates exactly once to _forge_issue_create.
#
# HOW THE ACTING ACCOUNT REACHES gh, now that phase 2 has landed: only ever
# through an environment variable, never a flag. A GH_TOKEN a caller exported
# before invoking this CLI is inherited by the child gh process with no code
# here to pass it along; this repository's own remembered account is applied by
# _forge_issue_create as a bash prefix assignment on the single `gh issue
# create` call, which never enters argv and never outlives that call. This
# paragraph used to state the inheritance half as the whole story and point at
# the second half as future work.
#
# INVARIANT (restated from the section header on purpose, not left
# implicit): a degraded or failed issue creation from this verb must NEVER
# be read by a caller as a reason to block PR creation. open-pr.md:481
# already documents this soft-fail behavior in prose; this verb's `status`
# field is what lets a future caller preserve it.
cmd_forge_issue_create() {
  check_jq

  local title="" body="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title)   shift; title="${1:-}" ;;
      --body)    shift; body="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-issue-create: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$title" ]; then
    echo "Error: forge-issue-create: --title <text> is required" >&2
    exit 1
  fi

  _forge_issue_create "$title" "$body"
}

# ============================================================================
# Forge Review-Thread Verbs — forge-pr-review-threads, forge-resolve-review-thread (US-007)
# ============================================================================
# Ports skills/resolve-pr-parallel/scripts/get-pr-comments's reviewThreads
# query and skills/resolve-pr-parallel/scripts/resolve-pr-thread's
# resolveReviewThread mutation into aimi-cli.sh -- the only two GraphQL call
# sites in this repository. Every identifier these two GraphQL documents
# consume (owner, repo, PR number, thread id) is bound through `gh api
# graphql`'s own -f/-F flags, never interpolated into the query text -- the
# same class of hand-built string this codebase's `jq -nc --arg` convention
# already prevents everywhere else, applied here to gh's own binding
# mechanism instead of jq.
#
# NOTE on the two query/mutation constants below: they are single-quoted
# verbatim ports and DO contain literal `$owner`, `$repo`, `$pr`, `$threadId`
# characters -- that is GraphQL's own variable-reference syntax (declared in
# each operation's signature, e.g. `($owner: String!)`, and bound externally
# by gh via -f/-F), not shell interpolation. Bash never expands anything
# inside a single-quoted string, so those tokens reach gh as inert literal
# text; nothing in this file ever substitutes a shell variable into either
# string. The actual security property enforced here (and asserted by this
# story's own tests) is that neither string ever contains a BASH-style
# expansion (`$(`, a backtick, or `${`) and that the gh invocations below
# bind owner/repo/pr/threadId ONLY via -f/-F flags -- never by building the
# query/mutation text with string concatenation or double-quoted
# interpolation.
#
# Built entirely on US-001's detect-forge (direct function call), US-002's
# shared degradation gate and generic three-way status envelope
# (_forge_bin_check, _forge_emit_status -- forge-contract.md is the single
# arbiter; no variant field-name casing or second degraded-reason field is
# introduced here), and US-003's forge-repo-info (direct function call,
# never a subprocess) for owner/repo auto-detection -- replacing
# get-pr-comments:14-20's own inline OWNER/REPO detection.
#
# forge-pr-review-threads is a READ verb: three-way found/not_found/error,
# QUIET degrade mode throughout (matches forge-issue-view's own posture --
# a caller must not gain a spurious warning it does not have today). A null
# GraphQL `pullRequest` is a confirmed not_found, never folded into error.
#
# forge-resolve-review-thread is a WRITE verb with NO fallback path (there
# is no gh subcommand or REST endpoint for resolving a review thread), so it
# follows forge-issue-create's MANDATORY-PRINT posture, but unlike forge-
# issue-create it distinguishes a CONFIRMED negative (the mutation ran;
# GraphQL says the thread id is invalid or inaccessible) from a
# could-not-attempt negative (gh missing, unsupported forge, or gh itself
# exiting non-zero for auth/network reasons). The confirmed negative reuses
# status="found" with a false `resolved` field -- the same pattern forge-
# auth-status already uses for a confirmed authenticated:false, per forge-
# contract.md's Three-Way Status Convention: a definitive answer is still a
# successful lookup, not an error. status="error" is reserved for the
# could-not-attempt case. _forge_resolve_review_thread itself always stays
# QUIET (JSON only, exit 0) so it is safely testable in isolation;
# cmd_forge_resolve_review_thread (the public wrapper) is the ONLY layer
# that prints the mandatory manual instruction and exits non-zero, driven
# purely by the JSON status field.

# Private helper holding the reviewThreads query, ported verbatim from
# get-pr-comments:27-68 (query body only -- the `gh api graphql -f owner=...
# -f query='` wrapper and the trailing `.data...edges | map(select(...))`
# jq pipeline are NOT part of the query text and live in
# _forge_pr_review_threads_github/_forge_pr_review_threads below instead,
# now expressed as a jq filter over the raw GraphQL response rather than a
# second external jq process piped from gh's own stdout).
_forge_review_threads_query() {
  printf '%s' '
query FetchReviewThreads($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      title
      url
      reviewThreads(first: 100) {
        totalCount
        edges {
          node {
            id
            isResolved
            isOutdated
            isCollapsed
            path
            line
            startLine
            diffSide
            comments(first: 100) {
              totalCount
              nodes {
                id
                author {
                  login
                }
                body
                createdAt
                updatedAt
                url
                outdated
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}'
}

# Private helper holding the resolveReviewThread mutation, ported verbatim
# from resolve-pr-thread:13-23.
_forge_resolve_review_thread_mutation() {
  printf '%s' '
mutation ResolveReviewThread($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
      path
      line
    }
  }
}'
}

# github adapter for forge-pr-review-threads. <pr_number>/<owner>/<repo> are
# already validated by cmd_forge_pr_review_threads before this ever runs;
# <all_threads> is the literal string "true"/"false". Binds owner/repo/pr
# via -f/-F only -- see the section header above for why the query text
# still contains literal `$owner`/`$repo`/`$pr` (GraphQL's own variable
# syntax, inert under bash single-quoting).
_forge_pr_review_threads_github() {
  local pr_number="$1" owner="$2" repo="$3" all_threads="$4" host="${5:-}"
  local stdout rc=0
  local stderr_out

  _forge_capture stdout stderr_out rc -- gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_number" \
    -f query="$(_forge_review_threads_query)" || true

  if [ "$rc" -ne 0 ]; then
    # gh's presence was already confirmed by the caller's _forge_bin_check
    # gate, so the classifier only separates not_authenticated from
    # cli_failed -- structurally, never by reading stderr_out's wording.
    local reason
    reason=$(_forge_classify_gh_failure_reason "$host")
    _forge_emit_status error "" "gh api graphql exited $rc: ${stderr_out:-unknown error}" "$reason"
    return 0
  fi

  local pr_present
  pr_present=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest // empty')
  if [ -z "$pr_present" ]; then
    _forge_emit_status not_found
    return 0
  fi

  local title url all_flag_json threads_json
  title=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest.title // ""')
  url=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest.url // ""')
  if [ "$all_threads" = "true" ]; then all_flag_json=true; else all_flag_json=false; fi

  # Collapses the edges/node GraphQL wrapper away (it carries no
  # caller-visible data of its own) and, without --all, filters to
  # isResolved==false and isOutdated==false -- matching get-pr-comments:68's
  # existing filter exactly.
  threads_json=$(printf '%s' "$stdout" | jq -c --argjson all "$all_flag_json" '
    [.data.repository.pullRequest.reviewThreads.edges[].node]
    | (if $all then . else map(select(.isResolved == false and .isOutdated == false)) end)
  ')

  local data_json
  data_json=$(jq -nc \
    --arg number "$pr_number" \
    --arg title "$title" \
    --arg url "$url" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber),
           title: (if $title == "" then null else $title end),
           url: (if $url == "" then null else $url end)},
      threads: $threads,
      unsupported_fields: []
    }')
  _forge_emit_status found "$data_json"
}

# gitlab adapter for forge-pr-review-threads (phase 3). <iid> is already
# validated as a positive integer by cmd_forge_pr_review_threads before this
# ever runs; <all_threads> is the literal string "true"/"false".
#
# glab's own documentation marks `glab mr note list` as EXPERIMENTAL and
# possibly unstable ("This feature is an experiment and is not ready for
# production use. It might be unstable or removed at any time.",
# docs/source/mr/note/list.md) -- disclosed here so a caller relying on this
# verb on GitLab knows the upstream tool does not yet consider it settled.
#
# VERIFICATION CEILING: glab was NOT installed on the machine this was
# written on, exactly as _forge_map_pr_field_gitlab's header already records
# for the same phase. Every flag and every JSON key below is read off glab's
# own documentation (docs/source/mr/note/list.md, whose examples pin both the
# array shape -- `glab mr note list -F json | jq '.[].notes[].body'` -- and
# the full-id extraction -- `jq -r '.[].id'`) and GitLab's Discussions API,
# never observed coming out of the real binary.
#
# VOCABULARY BOUNDARY. GitLab calls the unit a DISCUSSION; the normalized
# contract calls it a THREAD. That translation happens here and nowhere
# else: the word `discussion` must never reach the emitted envelope, whose
# key stays `threads` with GitHub's own per-thread field names.
#
# THE FILTER IS SERVER-SIDE, ON PURPOSE. `--state` (all|resolved|
# unresolved) is glab's own resolution-state filter, so the default call
# asks GitLab for the unresolved discussions instead of fetching everything
# and dropping the resolved ones locally. --all maps to `--state all`,
# matching the github adapter's "include what a plain call filters out".
#
# --owner/--repo ARE DELIBERATELY NOT FORWARDED. They are gh's flat
# owner/repo pair; a GitLab project is a nested group path
# (group/subgroup/project) that pair cannot express, and glab's own
# equivalent is a single `-R <full/path>` string. Rather than lossily
# rebuild one from the other, this adapter targets the repository the
# current working directory's remote already points at -- the same
# repository _detect_forge classified to get here.
#
# CAPABILITY GAPS, all reported through unsupported_fields per forge-
# contract.md ("An unpopulated capability-gated field is ALWAYS represented
# as null PLUS its name recorded in unsupported_fields -- never a bare,
# unmarked null"):
#   pr.title / pr.url                   `glab mr note list` returns
#     discussions only; supplying these would cost a SECOND `glab mr view`
#     round trip this verb deliberately does not make.
#   threads[].isOutdated                GitLab has no per-discussion
#     outdated flag at all. This is also why the default call cannot
#     reproduce the github adapter's second `isOutdated == false` filter --
#     there is nothing to filter on.
#   threads[].isCollapsed               a GitHub review-UI concept with no
#     GitLab counterpart.
#   threads[].comments.nodes[].url      GitLab's discussion notes carry no
#     per-note permalink in this payload.
#   threads[].comments.nodes[].outdated same gap as isOutdated, per note.
_forge_pr_review_threads_gitlab() {
  local iid="$1" all_threads="$2"
  local state_filter="unresolved"
  if [ "$all_threads" = "true" ]; then
    state_filter="all"
  fi

  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- glab mr note list "$iid" -F json --state "$state_filter" || true

  if [ "$rc" -ne 0 ]; then
    # A merge request that does not exist is a confirmed NOT_FOUND, not a
    # tool failure -- the same distinction _forge_issue_view already draws
    # from gh's stderr. The match is on the HTTP status code `404` rather
    # than on any English wording, because a status code is stable across
    # glab releases and locales while prose is neither. Anything else stays
    # cli_failed: misreading a could-not-attempt failure as a confirmed
    # answer is the dangerous direction, so the catch-all points the safe way.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status not_found
      return 0
    fi
    # cli_failed hard-coded rather than classified: _forge_classify_gh_failure_
    # reason is gh-specific (it calls _forge_auth_status_github), and this
    # repository has no glab auth probe to ask instead. Inventing one here
    # would duplicate whatever the phase's own account/auth story lands.
    _forge_emit_status error "" "glab mr note list exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # ZERO UNRESOLVED DISCUSSIONS IS A `found` RESULT CARRYING AN EMPTY LIST,
  # never not_found -- not_found means the MERGE REQUEST itself could not be
  # located. Conflating the two would make a clean review look like a broken
  # lookup. Go marshals an empty slice as `[]` and a nil slice as `null`, and
  # a command that printed nothing at all is the same fact again, so all
  # three collapse to the empty array here rather than to an error.
  local discussions_json=""
  if [ -n "$stdout" ]; then
    discussions_json=$(printf '%s' "$stdout" | jq -c '. // []' 2>/dev/null) || discussions_json=""
    if [ -z "$discussions_json" ]; then
      _forge_emit_status error "" "glab mr note list returned output that is not JSON" cli_failed
      return 0
    fi
  else
    discussions_json='[]'
  fi

  # The one place GitLab's discussion vocabulary becomes the contract's
  # thread vocabulary.
  #
  # `id` is emitted VERBATIM as GitLab's own full 40-character hex discussion
  # id -- never the 8-character prefix glab's TEXT output displays. That is
  # what makes the identifier ROUND TRIP: forge-resolve-review-thread hands
  # this exact string straight back to `glab mr note resolve`, which accepts a
  # full id, an 8+ character prefix, or an integer note id. Emitting a prefix
  # here and resolving by full id (or the reverse) would work against a fake
  # and fail against the real service.
  #
  # isResolved is DERIVED, because GitLab records resolution per NOTE, not per
  # discussion: a discussion counts as resolved when it has at least one
  # resolvable note and every one of them is resolved. A discussion with no
  # resolvable notes (a plain comment thread) is not resolvable, hence false.
  #
  # path/line/diffSide come from the FIRST note's diff position, which is the
  # note that anchored the discussion to the diff; a general (non-diff)
  # discussion has no position and yields nulls for all three. diffSide is
  # derived rather than read: GitLab records new_line for the post-image side
  # and old_line for the pre-image side, which are GitHub's RIGHT and LEFT.
  #
  # Note ids are integers in GitLab and strings in GitHub, so they are cast to
  # string here -- the contract's comment id stays one type across forges.
  local threads_json
  threads_json=$(printf '%s' "$discussions_json" | jq -c '
    [ .[] | {
        id: .id,
        isResolved: (
          [ .notes[]? | select(.resolvable == true) ] as $resolvable
          | if ($resolvable | length) == 0
            then false
            else ($resolvable | all(.resolved == true))
            end
        ),
        isOutdated: null,
        isCollapsed: null,
        path: (.notes[0].position.new_path // .notes[0].position.old_path // null),
        line: (.notes[0].position.new_line // .notes[0].position.old_line // null),
        startLine: (.notes[0].position.line_range.start.new_line
                    // .notes[0].position.line_range.start.old_line // null),
        diffSide: (
          if (.notes[0].position.new_line // null) != null then "RIGHT"
          elif (.notes[0].position.old_line // null) != null then "LEFT"
          else null
          end
        ),
        comments: {
          totalCount: ((.notes // []) | length),
          nodes: [ (.notes // [])[] | {
            id: (.id | tostring),
            author: {login: (.author.username // null)},
            body: (.body // null),
            createdAt: (.created_at // null),
            updatedAt: (.updated_at // null),
            url: null,
            outdated: null
          } ]
        }
      } ]
  ' 2>/dev/null) || threads_json=""

  # A payload that parsed as JSON but is not the ARRAY OF DISCUSSIONS the
  # transform above expects (an error object, say) would otherwise reach
  # `jq --argjson threads ""` below and spill a raw jq error onto stderr --
  # unacceptable on a verb whose degrade mode is QUIET. Caught here instead.
  if [ -z "$threads_json" ]; then
    _forge_emit_status error "" "glab mr note list returned JSON that is not a discussion array" cli_failed
    return 0
  fi

  local data_json
  data_json=$(jq -nc \
    --arg number "$iid" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber), title: null, url: null},
      threads: $threads,
      unsupported_fields: ["pr.title",
                           "pr.url",
                           "threads[].isOutdated",
                           "threads[].isCollapsed",
                           "threads[].comments.nodes[].url",
                           "threads[].comments.nodes[].outdated"]
    }')
  _forge_emit_status found "$data_json"
}

# ----------------------------------------------------------------------------
# GITEA REVIEW-THREAD ADAPTERS (phase 4). This header covers BOTH
# _forge_pr_review_threads_gitea (immediately below) and
# _forge_resolve_review_thread_gitea (beside its gitlab sibling further down),
# because every constraint here applies to the pair.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY FLAG OR KEY BELOW. `tea` is
# NOT installed on the machine this was written on. Not one subcommand, flag
# or JSON key below has ever been observed coming out of the real binary:
# every one was read off `gitea/tea` `main` source on 2026-08-06, file and
# line cited per claim. This is the same ceiling phase 3 declared for glab
# (:4380) and that this phase's own field mapper already declared for tea
# (:4497). The tests prove WHICH ARGV this file emits and HOW it parses a
# fixture, never what real tea does with either.
#
# The two halves are NOT equally well covered by that, and saying so is the
# point of declaring the ceiling rather than merely noting it. Argv-shape
# assertions are SOUND against a fake -- the defect this adapter can plausibly
# ship on the emitting side is a wrong flag, and a wrong flag is visible in
# the recorded argv. Key names and document shapes are the opposite: the stub
# emits whatever the author believed, so the assertion only confirms the
# author agrees with themselves and a wrong key passes green on both sides.
# tea's output shape is this section's unobservable.
#
# VERSION FLOOR: tea >= v0.14.0. `tea pulls review-comments`, `tea pulls
# resolve` and `tea pulls unresolve` all landed in tea v0.14.0; the current
# release is v0.15.1 (2026-08-02). An older tea answers with an unknown-
# subcommand error, which is a non-zero exit carrying tea's own stderr and is
# therefore reported as cli_failed -- never as a confirmed not_found.
#
# THE LIST PATH MARSHALS EVERY VALUE AS A STRING. tea emits two different JSON
# shapes for the same resource: a purpose-built typed object on the DETAIL
# path (`tea pulls <index> -o json`) and, on the LIST path, an array of rows
# whose keys are snake_cased and whose values are ALWAYS JSON strings
# (orderedRow.MarshalJSON, modules/print/table.go:187-208, marshals a
# map[string]string). `review-comments` is a LIST path. That is why `line` is
# coerced to a number below and why `isResolved` is derived from a STRING
# comparison. _forge_map_pr_field_gitea (:4548) works the DETAIL path; its
# assumptions do not carry across.
#
# NO SERVER-SIDE RESOLUTION FILTER EXISTS, so the filter is LOCAL -- the exact
# opposite of the gitlab arm above, which asks GitLab for `--state
# unresolved` (:6600) and says so in its own header. `tea pulls
# review-comments` carries only flags.AllDefaultFlags plus `--fields`
# (cmd/pulls/review_comments.go:31); there is no `--state` and no other
# resolution-state selector to pass. The default (unresolved-only) view is
# therefore produced by dropping rows whose `resolver` is non-empty AFTER the
# call, and `--all` skips that drop. Reading the returned list can never tell
# a local filter from a server-side one, which is why the accompanying test
# asserts the ABSENCE of `--state` from the recorded argv and drives a fixture
# that carries both a resolved and an unresolved row.
#
# EVERY THREAD IS DEGENERATE: EXACTLY ONE COMMENT. tea lists review COMMENTS,
# flattened across every review (modules/task/pull_review_comment.go:16-44
# iterates the pull request's reviews and concatenates their comments), and
# exposes no thread/conversation object anywhere. So one review comment
# becomes one thread with comments.totalCount == 1. Inventing grouping by
# `path`, by reviewer or by timestamp would fabricate a structure the forge
# does not have; the gap is DECLARED instead, as `threads[].grouping`.
#
# `threads[].grouping` IS EMITTED AS AN EXPLICIT null KEY, not merely named.
# It is the one gap this forge has that neither other forge has, and it names
# a missing STRUCTURE rather than a missing field -- which is exactly why it
# is spelled out as a key: forge-contract.md's rule is "null PLUS its name
# recorded in unsupported_fields, never a bare unmarked null", and a name in
# the array with no key in the payload would be the mirror-image omission. A
# reader who dumps one gitea thread sees `"grouping": null` and can look the
# name up. The key is gitea-only by construction and no consumer reads it.
#
# `threads[].diffSide` IS PERMANENTLY UNRECOVERABLE HERE, and the reason is
# NOT the usual "the forge has no such field". tea prints ONE `line` column,
# collapsing LineNum and OldLineNum into it (modules/print/
# pull_review_comment.go:52-59 falls back from the one to the other), so by
# the time the value reaches this adapter there is nothing left to say whether
# it was the post-image or the pre-image side. The gitlab arm CAN derive
# RIGHT/LEFT because GitLab hands it separate new_line and old_line keys
# (:6680-6685). Do not port that derivation here -- there is no second number
# to branch on, and guessing RIGHT would be a fabricated answer.
#
# NO ACCOUNT OVERRIDE IS APPLIED, AND THAT IS A SAFETY PROPERTY, NOT AN
# OMISSION. tea reads GH_TOKEN as a fallback credential
# (modules/context/context_login.go:15-51: it prefers GITEA_TOKEN and falls
# back to GH_TOKEN when GITEA_TOKEN is empty), while
# _forge_account_override_slots (:2983-2997) deliberately defaults an empty
# override slot to the AMBIENT GH_TOKEN and every routed github write
# prefix-assigns it. Copying that prefix-assignment shape onto a tea
# invocation would hand a GitHub token to a Gitea instance. Neither gitea
# function below assigns or exports GH_TOKEN, GH_ENTERPRISE_TOKEN,
# GITEA_TOKEN or GITEA_INSTANCE_URL, and a test counts those assignments over
# both function bodies to keep it that way.
#
# --owner/--repo ARE NOT FORWARDED, for the same reason the gitlab arm gives:
# they are gh's flat owner/repo pair, and tea addresses the repository through
# the current working directory's remote. Both gitea arms therefore return
# BEFORE _forge_pr_review_threads' gh-specific owner/repo resolution block.
#
# FAILURE CLASSIFICATION. tea exits 1 uniformly for every error (main.go:18-30
# prints `Error: %v` and calls os.Exit(1)) with no distinct not-found code, so
# a `404` in stderr is the ONLY confirmed negative -- matched on the HTTP
# status code rather than on English wording, exactly as the gitlab arms
# above. Every other non-zero exit stays status=error/reason=cli_failed
# carrying tea's own stderr. Misreading a could-not-attempt failure as a
# confirmed answer is the dangerous direction; the catch-all points the safe
# way.
#
# CAPABILITY GAPS, all reported through unsupported_fields per
# forge-contract.md:
#   pr.title / pr.url                   `tea pulls review-comments` returns
#     comments only; supplying these would cost a SECOND `tea pulls <index>`
#     round trip this verb deliberately does not make -- the same argument
#     the gitlab arm makes at :6579-6581.
#   threads[].startLine                 tea has no start-line field at all.
#   threads[].diffSide                  unrecoverable, see above.
#   threads[].isOutdated / isCollapsed  no field; GitHub review-UI concepts.
#   threads[].grouping                  no conversation object, see above.
#   threads[].comments.nodes[].outdated same gap as isOutdated, per comment.
#
# AND ONE FIELD THAT IS *NOT* A GAP HERE, though it is on GitLab:
#   threads[].comments.nodes[].url      tea's review-comment field allowlist
#     carries `url` (modules/print/pull_review_comment.go:13-23), so it is
#     REQUESTED, populated and deliberately absent from unsupported_fields.
#     GitLab lists it as a gap (:6721); copying that array wholesale is the
#     expected mistake, and a test asserts the name appears nowhere in the
#     gitea array.
# ----------------------------------------------------------------------------

# gitea adapter for forge-pr-review-threads. <index> is already validated as a
# positive integer by cmd_forge_pr_review_threads before this ever runs;
# <all_threads> is the literal string "true"/"false". See the GITEA
# REVIEW-THREAD ADAPTERS header directly above for the verification ceiling,
# the tea >= v0.14.0 version floor, and every capability gap named below.
_forge_pr_review_threads_gitea() {
  local index="$1" all_threads="$2"
  local stdout rc=0
  local stderr_out

  # `-f` is tea's OWN field selector (--fields, cmd/flags/generic.go:157), a
  # CSV over a fixed allowlist -- never a gh-style `--json <field-list>`,
  # which tea does not have. `-o json` selects the output format. The list is
  # the full review-comment allowlist (modules/print/
  # pull_review_comment.go:13-23) rather than the subcommand's own narrower
  # default (id,path,line,body,reviewer,resolver), because `created`,
  # `updated` and `url` are all contract fields this verb must populate.
  #
  # No account override, no GH_TOKEN prefix assignment -- see the header.
  _forge_capture stdout stderr_out rc -- tea pulls review-comments "$index" \
    -f id,path,line,body,reviewer,resolver,created,updated,url -o json || true

  if [ "$rc" -ne 0 ]; then
    # tea has ONE exit code for every failure, so `404` in stderr is the only
    # confirmed negative. Everything else is a could-not-attempt.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status not_found
      return 0
    fi
    _forge_emit_status error "" "tea pulls review-comments exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # ZERO REVIEW COMMENTS IS A `found` RESULT CARRYING AN EMPTY LIST, never
  # not_found -- not_found means the PULL REQUEST itself could not be located.
  # Go marshals an empty slice as `[]` and a nil slice as `null`, and a
  # command that printed nothing at all is the same fact again, so all three
  # collapse here rather than to an error.
  local comments_json=""
  if [ -n "$stdout" ]; then
    comments_json=$(printf '%s' "$stdout" | jq -c '. // []' 2>/dev/null) || comments_json=""
    if [ -z "$comments_json" ]; then
      _forge_emit_status error "" "tea pulls review-comments returned output that is not JSON" cli_failed
      return 0
    fi
  else
    comments_json='[]'
  fi

  local all_flag_json
  if [ "$all_threads" = "true" ]; then all_flag_json=true; else all_flag_json=false; fi

  # The one place a tea review COMMENT becomes a contract THREAD.
  #
  # The select() is the LOCAL resolution filter tea offers no server-side
  # equivalent for. `resolver` is a username or the empty string -- there is
  # no boolean anywhere in the payload -- so isResolved is DERIVED from it by
  # the same comparison, and the two can never disagree.
  #
  # `line` is coerced to a NUMBER because the LIST path marshals it as the
  # string tea printed; `tonumber?` yields nothing for a non-numeric value,
  # which `// null` then turns into an honest null rather than a zero.
  # `id` goes the other way and is cast to STRING, so the contract's thread
  # and comment ids stay one type across all three forges.
  #
  # comments.totalCount is the literal 1: tea exposes no conversation object,
  # so one comment is the whole thread. See the header.
  local threads_json
  threads_json=$(printf '%s' "$comments_json" | jq -c --argjson all "$all_flag_json" '
    [ .[]
      | select($all or (((.resolver // "") | tostring) == ""))
      | {
          id: (.id | tostring),
          isResolved: (((.resolver // "") | tostring) != ""),
          isOutdated: null,
          isCollapsed: null,
          grouping: null,
          path: (if ((.path // "") | tostring) == "" then null else (.path | tostring) end),
          line: ((.line | tonumber?) // null),
          startLine: null,
          diffSide: null,
          comments: {
            totalCount: 1,
            nodes: [ {
              id: (.id | tostring),
              author: {login: (if ((.reviewer // "") | tostring) == "" then null else (.reviewer | tostring) end)},
              body: (if ((.body // "") | tostring) == "" then null else (.body | tostring) end),
              createdAt: (if ((.created // "") | tostring) == "" then null else (.created | tostring) end),
              updatedAt: (if ((.updated // "") | tostring) == "" then null else (.updated | tostring) end),
              url: (if ((.url // "") | tostring) == "" then null else (.url | tostring) end),
              outdated: null
            } ]
          }
        } ]
  ' 2>/dev/null) || threads_json=""

  # A payload that parsed as JSON but is not the ARRAY OF COMMENTS the
  # transform above expects (an error object, say) would otherwise reach
  # `jq --argjson threads ""` below and spill a raw jq error onto stderr --
  # unacceptable on a verb whose degrade mode is QUIET. Caught here instead,
  # exactly as the gitlab arm does.
  if [ -z "$threads_json" ]; then
    _forge_emit_status error "" "tea pulls review-comments returned JSON that is not a review-comment array" cli_failed
    return 0
  fi

  local data_json
  data_json=$(jq -nc \
    --arg number "$index" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber), title: null, url: null},
      threads: $threads,
      unsupported_fields: ["pr.title",
                           "pr.url",
                           "threads[].startLine",
                           "threads[].diffSide",
                           "threads[].isOutdated",
                           "threads[].isCollapsed",
                           "threads[].grouping",
                           "threads[].comments.nodes[].outdated"]
    }')
  _forge_emit_status found "$data_json"
}

# Resolves forge/owner/repo, routes a forge with no adapter or a missing
# forge CLI to a QUIET status=error result, and otherwise delegates to the
# github, gitlab or gitea adapter. Owner/repo are resolved via US-003's
# _forge_repo_info as a direct function call (never a `$AIMI_CLI
# forge-repo-info` subprocess, never a second private gh-repo-view call)
# whenever --owner/--repo are not both supplied, replacing
# get-pr-comments:14-20's own inline OWNER/REPO detection -- a GITHUB-ONLY
# step, which is why the gitlab arm returns before it (glab addresses the
# repository through the cwd remote, not an owner/repo pair).
_forge_pr_review_threads() {
  local pr_number="$1" owner="$2" repo="$3" all_threads="$4"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) so it
  # can be handed to the github adapter, which passes it to the classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  # GitLab returns HERE, before the owner/repo resolution below: that step is
  # gh-specific and glab needs no owner/repo pair at all. Degradation runs
  # through the SAME shared _forge_bin_check gate the github arm uses, in the
  # same quiet mode, naming `glab` rather than `gh`.
  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      _forge_emit_status error "" "glab not found -- this review-thread lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_pr_review_threads_gitlab "$pr_number" "$all_threads"
    return 0
  fi

  # Gitea returns HERE too, and for the same reason: `tea` addresses the
  # repository through the cwd remote and has no owner/repo pair to be given.
  # Same shared _forge_bin_check gate, same quiet mode, naming `tea`.
  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      _forge_emit_status error "" "tea not found -- this review-thread lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_pr_review_threads_gitea "$pr_number" "$all_threads"
    return 0
  fi

  # Still reachable: `unknown`, the classification _detect_forge_classify_host
  # answers for any host that is not one of the three named adapters. It is
  # now the ONLY forge word that reaches this branch, since AIMI_FORGE_TYPE
  # validates against github|gitlab|gitea (:2130).
  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-pr-review-threads: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this review-thread lookup did not run automatically." cli_missing
    return 0
  fi

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    local repo_info repo_status
    repo_info=$(_forge_repo_info)
    repo_status=$(printf '%s' "$repo_info" | jq -r '.status')
    if [ "$repo_status" = "found" ]; then
      [ -n "$owner" ] || owner=$(printf '%s' "$repo_info" | jq -r '.data.owner')
      [ -n "$repo" ]  || repo=$(printf '%s' "$repo_info" | jq -r '.data.repo')
    fi
  fi

  # cli_failed, NOT a fifth enum value of its own and NOT routed through the
  # classifier: no gh invocation happens on this branch, so there is nothing
  # to re-check auth against, and forge-contract.md's cli_failed already
  # names "an owner/repo that could not be auto-resolved" as one of the
  # catch-all's cases. A fifth value for exactly one call site would be enum
  # proliferation for a single caller-input edge case.
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    _forge_emit_status error "" "forge-pr-review-threads: could not resolve owner/repo -- pass --owner and --repo explicitly." cli_failed
    return 0
  fi

  _forge_pr_review_threads_github "$pr_number" "$owner" "$repo" "$all_threads" "$host"
}

# Read verb: found | not_found | error, per forge-contract.md's Three-Way
# Status Convention. Output: {status, data, message}; data (when found)
# carries {pr: {number, title, url}, threads: [...], unsupported_fields}.
# Each thread carries get-pr-comments' current fields unchanged: id,
# isResolved, isOutdated, isCollapsed, path, line, startLine, diffSide, and
# comments: {totalCount, nodes: [{id, author: {login}, body, createdAt,
# updatedAt, url, outdated}]}.
#
# On GitLab and on Gitea the SHAPE is identical -- same keys, same three-way
# status -- but several fields are capability-gated and come back null with
# their names in `unsupported_fields`; see _forge_pr_review_threads_gitlab's
# and _forge_pr_review_threads_gitea's headers for the list and the reason for
# each. A merge request with zero unresolved discussions, or a Gitea pull
# request with zero unresolved review comments, is `found` with an empty
# `threads` array, NOT `not_found`. Gitea threads additionally carry a
# `grouping` key, always null and always declared in `unsupported_fields`:
# tea exposes no conversation object, so each thread is exactly one comment.
# --owner/--repo are honored on GitHub only.
# Usage: aimi-cli.sh forge-pr-review-threads --pr <number> [--owner <owner>
# --repo <repo>] [--all] [--project <path>]
cmd_forge_pr_review_threads() {
  check_jq

  local pr_number="" owner="" repo="" all_threads="false" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)      shift; pr_number="${1:-}" ;;
      --owner)   shift; owner="${1:-}" ;;
      --repo)    shift; repo="${1:-}" ;;
      --all)     all_threads="true" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-review-threads: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$pr_number" ]; then
    echo "Usage: aimi-cli.sh forge-pr-review-threads --pr <number> [--owner <owner> --repo <repo>] [--all] [--project <path>]" >&2
    exit 1
  fi

  # Fail-fast usage check BEFORE the PR number is ever passed to gh -- the
  # primary injection defense is the -f/-F binding in the github adapter
  # above, not this pattern check.
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-pr-review-threads: --pr must be a positive integer (got: $pr_number)" >&2
    exit 1
  fi

  if [ -n "$owner" ] && ! [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: forge-pr-review-threads: invalid --owner value: $owner" >&2
    exit 1
  fi

  if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: forge-pr-review-threads: invalid --repo value: $repo" >&2
    exit 1
  fi

  _forge_pr_review_threads "$pr_number" "$owner" "$repo" "$all_threads"
}

# ----------------------------------------------------------------------------
# GITEA CAPABILITY-GAP NOTE -- REWRITTEN IN PHASE 4, BECAUSE ITS FACTUAL
# CLAIM WAS FALSE.
#
# WHAT THIS NOTE USED TO SAY, and what is now retracted: written in phase 1
# as documentation only, it ruled that a Gitea/Forgejo `tea` adapter could
# not resolve a review thread by any means, and that this was a PERMANENT
# capability gap rather than the temporary state an unwritten adapter is in.
# Source falsifies both halves. `tea pulls review-comments <pull index>`
# (cmd/pulls/review_comments.go:24-32) lists a pull request's review
# comments, and `tea pulls resolve <comment id>` / `tea pulls unresolve`
# (cmd/pulls/resolve.go, unresolve.go) mark one resolved or unresolved. All
# three landed in tea v0.14.0; the current release is v0.15.1. Both verbs are
# ROUTED for gitea today -- see the GITEA REVIEW-THREAD ADAPTERS section
# above.
#
# WHAT THE REAL GAP IS: GROUPING, not resolution, and it is both narrower and
# different from the ruling it replaces. tea lists review COMMENTS, flattened
# across every review (modules/task/pull_review_comment.go:16-44), and
# exposes no thread/conversation object at all, so the adapter emits one
# DEGENERATE single-comment thread per review comment. Alongside it,
# `threads[].diffSide` is unrecoverable, and for a reason that is not the
# usual absence: tea collapses LineNum and OldLineNum into one printed
# column (modules/print/pull_review_comment.go:52-59), leaving nothing to
# tell the post-image side from the pre-image one -- unlike GitLab, whose
# separate new_line/old_line keys the gitlab arm above genuinely does derive
# RIGHT/LEFT from. Add `threads[].startLine`, `threads[].isOutdated`,
# `threads[].isCollapsed`, `pr.title` and `pr.url`, and that is the whole
# gap.
#
# WHAT THE ADVICE STILL SAYS, UNCHANGED, because only the factual claim was
# wrong: a PERMANENT capability gap is reported through the
# `unsupported_fields` array naming the thing that is missing, never by
# reusing the generic no-adapter `message` text an unwritten adapter
# produces. "This forge cannot do this at all" and "nobody wrote the adapter
# yet" are two different facts, and collapsing them would make a permanent
# gap look like a temporary one. Applying that advice is what
# `threads[].grouping` in the gitea listing arm's own unsupported_fields is.
#
# WHAT CHANGED IS THE WORKED EXAMPLE. The old note offered an
# unsupported_fields entry naming the resolveReviewThread mutation as the
# value to emit. That is now exactly the WRONG answer: resolution is
# supported on this forge, so naming it as a gap would report a capability
# the adapter has as one it lacks -- the same collapse the advice above
# exists to prevent, pointing the other way.
# ----------------------------------------------------------------------------
# github adapter for forge-resolve-review-thread. <thread_id> is already
# validated by cmd_forge_resolve_review_thread before this ever runs. Binds
# threadId via -f only -- see the section header above for why the mutation
# text still contains a literal `$threadId` (GraphQL's own variable syntax).
# Always QUIET and always returns 0 -- found/error are three data outcomes,
# not exit codes; cmd_forge_resolve_review_thread (the public wrapper) is
# the only layer that prints the MANDATORY manual instruction and exits
# non-zero, driven by this function's JSON `status` field.
# gitlab adapter for forge-resolve-review-thread (phase 3). <thread_id> is
# already validated by cmd_forge_resolve_review_thread before this ever runs.
#
# EXPERIMENTAL UPSTREAM: glab's own documentation marks `glab mr note resolve`
# as an experiment "not ready for production use ... might be unstable or
# removed at any time" (docs/source/mr/note/resolve.md).
#
# That is a DISCLOSURE to whoever relies on this verb, not a reason to skip
# the routing: without it a GitLab caller gets no automatic resolve at all,
# which is strictly worse than an automatic one whose upstream is still
# settling.
#
# RESOLVES ONLY; POSTS NO REPLY. `glab mr note resolve` marks the discussion
# resolved and writes no comment, which is exactly this verb's established
# meaning here -- phase 2's handoff records that forge-resolve-review-thread
# resolves a thread and does not post a comment, and that no reply call site
# exists anywhere in this repository. The two agree, so nothing is
# special-cased: this adapter issues ONE glab invocation and it is not a
# note-creating one.
#
# THE MERGE REQUEST IS NOT NAMED, DELIBERATELY. `glab mr note resolve
# [<id> | <branch>] <discussion-id>` takes the merge request as an OPTIONAL
# leading positional and auto-detects it from the current branch when it is
# omitted -- which is the only form this verb can use, because
# forge-resolve-review-thread's contract carries a thread id and nothing
# else (GitHub's node id is globally unique, so no PR number was ever part
# of the signature).
#
# The id is passed through VERBATIM, byte for byte as
# _forge_pr_review_threads_gitlab emitted it. glab accepts a full 40-char hex
# discussion id, an 8+ character prefix, or an integer note id; the listing
# side emits the full id, so nothing here re-derives, truncates or re-formats
# it. That is the round trip, and it is what stops a fake from making a
# prefix/full-id mismatch look correct.
#
# Always QUIET and always returns 0, same as the github adapter.
_forge_resolve_review_thread_gitlab() {
  local thread_id="$1"
  local stdout rc=0
  local stderr_out

  # No account override is applied on this path. The GH_TOKEN/
  # GH_ENTERPRISE_TOKEN prefix assignment the github arm carries is gh's own
  # mechanism; the equivalent question for glab belongs to this phase's
  # account story and is not answered by guessing at one here.
  _forge_capture stdout stderr_out rc -- glab mr note resolve "$thread_id" || true

  if [ "$rc" -ne 0 ]; then
    # A discussion id GitLab cannot find is a CONFIRMED negative (the call
    # ran; the answer is "no such thread"), reported as status="found" with
    # resolved=false -- byte-identical to the github adapter's own
    # confirmed-invalid-id result, per forge-contract.md's Three-Way Status
    # Convention: a definitive answer is still a successful lookup.
    #
    # Matched on the HTTP status code `404` ONLY, never on English wording:
    # a status code is stable across glab releases and locales. Every other
    # failure -- glab could not auto-detect a merge request for this branch,
    # the network was down, the token expired -- stays status="error", so the
    # wrapper prints its manual instruction and exits non-zero. Reading a
    # could-not-attempt failure as a confirmed answer is the dangerous
    # direction; this narrow match points the safe way.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # cli_failed hard-coded rather than classified, for the same reason
    # _forge_pr_review_threads_gitlab gives: the shared classifier is
    # gh-specific and there is no glab auth probe in this repository.
    _forge_emit_status error "" "glab mr note resolve exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # glab reports success by exit status, not by a JSON document, and it is
  # given no `-F json` flag (its resolve subcommand documents none). So the
  # thread object is rebuilt from what is known for certain: the id that was
  # just resolved, and the fact that it now is. path/line are GitHub's, come
  # from the GraphQL mutation's own response there, and have no counterpart
  # in glab's output -- null plus unsupported_fields, per forge-contract.md.
  _forge_emit_status found "$(jq -nc --arg id "$thread_id" '{
    resolved: true,
    thread: {id: $id, isResolved: true, path: null, line: null},
    unsupported_fields: ["thread.path", "thread.line"]
  }')"
}

# gitea adapter for forge-resolve-review-thread (phase 4). <thread_id> is
# already validated by cmd_forge_resolve_review_thread before this ever runs.
# See the GITEA REVIEW-THREAD ADAPTERS header above _forge_pr_review_threads_
# gitea for the verification ceiling, the tea >= v0.14.0 version floor, and
# the GH_TOKEN hazard that forbids any account override on this path.
#
# RESOLVES ONLY; POSTS NO REPLY. `tea pulls resolve` marks the review comment
# resolved and writes no comment of its own, which is this verb's established
# meaning here -- the same property the gitlab arm above insists on. This
# adapter issues ONE tea invocation and it is not a comment-creating one.
#
# THE PULL REQUEST IS NOT NAMED, because it is not part of the identifier.
# `tea pulls resolve` takes a COMMENT id, which is what makes the round trip
# work: _forge_pr_review_threads_gitea emits tea's own `id` and this hands
# that exact string back (ResolvePullReviewComment consumes the same id,
# modules/task/pull_review_comment.go:47-57). Nothing here re-derives,
# truncates or re-formats it. A numeric id also passes
# cmd_forge_resolve_review_thread's existing ^[A-Za-z0-9+/=_-]+$ guard
# unchanged, so that guard needed no edit for this forge.
#
# Always QUIET and always returns 0, same as the other two adapters.
_forge_resolve_review_thread_gitea() {
  local thread_id="$1"
  local stdout rc=0
  local stderr_out

  # No account override, no GH_TOKEN prefix assignment: tea reads GH_TOKEN as
  # a fallback credential, so the github arm's shape would hand a GitHub token
  # to a Gitea instance. See the section header.
  _forge_capture stdout stderr_out rc -- tea pulls resolve "$thread_id" || true

  if [ "$rc" -ne 0 ]; then
    # A comment id Gitea cannot find is a CONFIRMED negative (the call ran;
    # the answer is "no such comment"), reported as status="found" with
    # resolved=false -- byte-identical to the other two adapters' own
    # confirmed-invalid-id result, per forge-contract.md's Three-Way Status
    # Convention. Matched on the HTTP status code `404` only, never on
    # English wording, and every other failure stays status="error" so the
    # wrapper prints its manual instruction and exits non-zero.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # cli_failed hard-coded rather than classified, for the same reason the
    # gitlab arm gives: the shared classifier is gh-specific and there is no
    # tea auth probe in this repository.
    _forge_emit_status error "" "tea pulls resolve exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # tea reports success by exit status, not by a JSON document: it prints
  # `Comment %d resolved` to stdout (modules/task/pull_review_comment.go:55)
  # and returns nothing structured. So the thread object is rebuilt from what
  # is known for certain -- the id that was just resolved, and the fact that
  # it now is -- reusing the shape `glab mr note resolve` already established
  # directly above. path/line are GitHub's, come from the GraphQL mutation's
  # own response there, and have no counterpart in tea's output: null plus
  # unsupported_fields, per forge-contract.md.
  _forge_emit_status found "$(jq -nc --arg id "$thread_id" '{
    resolved: true,
    thread: {id: $id, isResolved: true, path: null, line: null},
    unsupported_fields: ["thread.path", "thread.line"]
  }')"
}

_forge_resolve_review_thread() {
  local thread_id="$1"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) purely
  # so the generic-failure branch below can hand it to the shared classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  # Same shared _forge_bin_check gate, same quiet mode, naming `glab` rather
  # than `gh`. The wrapper below is still the only layer that prints and
  # exits non-zero, driven purely by the JSON status field -- so a missing
  # glab degrades through exactly the path a missing gh already does.
  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      _forge_emit_status error "" "glab not found -- this thread could not be resolved automatically." cli_missing
      return 0
    fi
    _forge_resolve_review_thread_gitlab "$thread_id"
    return 0
  fi

  # Same gate again for gitea, naming `tea`. The wrapper below stays the only
  # layer that prints and exits non-zero, so a missing tea degrades through
  # exactly the path a missing gh already does.
  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      _forge_emit_status error "" "tea not found -- this thread could not be resolved automatically." cli_missing
      return 0
    fi
    _forge_resolve_review_thread_gitea "$thread_id"
    return 0
  fi

  # Still reachable by `unknown` -- the only forge word left with no adapter.
  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-resolve-review-thread: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this thread could not be resolved automatically." cli_missing
    return 0
  fi

  # Resolved once, for the mutation below and for the failure classifier that
  # judges it. See the ROUTING RULE block above the forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # WRITE 4. Same prefix-assignment shape as the other three. The nested
  # `$(_forge_resolve_review_thread_mutation)` substitution is evaluated in this
  # shell BEFORE _forge_capture is entered, so the prefix assignment does not
  # disturb it.
  local stdout rc=0
  local stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh api graphql -f threadId="$thread_id" \
    -f query="$(_forge_resolve_review_thread_mutation)" || true

  # gh api graphql exits non-zero when the GraphQL response's own `errors`
  # array is non-empty -- a mutation targeting an invalid/inaccessible node
  # id is exactly this case. That non-zero exit is a CONFIRMED negative
  # answer, not a tool failure, so it must not fall into the generic
  # "gh could not attempt this" branch below. GitHub's GraphQL API names
  # this failure mode with the fixed message "Could not resolve to a node
  # with the global id of" regardless of which mutation triggered it -- the
  # same style of stderr pattern-match _forge_issue_view already uses to
  # distinguish "no such issue" from "gh is broken".
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$stderr_out" | grep -qi "could not resolve to a node"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # Reached only after the confirmed-invalid-id match above already
    # failed, so gh genuinely broke. gh's presence was confirmed by the
    # _forge_bin_check gate above, so the classifier only separates
    # not_authenticated from cli_failed -- structurally, never by reading
    # stderr_out's wording.
    #
    # ROUTED, and this is the ONLY classifier call inside a write path. Left
    # unrouted it would re-check the MACHINE account's auth after a mutation
    # that failed as a DIFFERENT account -- an overridden account whose token
    # expired would be classified against the wrong account entirely. Under the
    # override `gh auth status` reports the env-token account, which is exactly
    # the one whose failure is being classified. The prefix assignment is at
    # this call site; _forge_classify_gh_failure_reason itself is unmodified,
    # and its other two callers are pure reads that stay unrouted.
    local reason
    reason=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
      _forge_classify_gh_failure_reason "$host")
    _forge_emit_status error "" "gh api graphql exited $rc: ${stderr_out:-unknown error}" "$reason"
    return 0
  fi

  # Defensive fallback for a gh response shape that returns exit 0 with a
  # populated top-level `errors` array instead of a non-zero exit -- the
  # same confirmed-negative outcome, reached by inspecting the body instead
  # of the exit code.
  local errors_count
  errors_count=$(printf '%s' "$stdout" | jq -r '(.errors // []) | length')
  if [ "$errors_count" != "0" ]; then
    _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
    return 0
  fi

  local thread_json
  thread_json=$(printf '%s' "$stdout" | jq -c '.data.resolveReviewThread.thread // empty')
  # cli_failed hard-coded rather than classified: gh itself exited 0 here,
  # so nothing failed at the tool level and there is no failure to re-check
  # auth against -- only the response shape is unexpected.
  if [ -z "$thread_json" ]; then
    _forge_emit_status error "" "gh api graphql returned no thread and no errors for resolveReviewThread" cli_failed
    return 0
  fi

  local data_json
  data_json=$(printf '%s' "$thread_json" | jq -c '{
    resolved: .isResolved,
    thread: {id: .id, isResolved: .isResolved, path: .path, line: .line},
    unsupported_fields: []
  }')
  _forge_emit_status found "$data_json"
}

# Write verb with NO fallback path -- MANDATORY-PRINT degrade mode.
# Output: {status: "found"|"error", data, message}. status=="found" covers
# BOTH a successful resolve (data.resolved=true) and a confirmed-invalid
# thread id (data.resolved=false, the mutation ran) -- both exit 0, no
# stderr. status=="error" means gh could not even attempt the mutation
# (missing binary, unsupported forge, or gh itself exiting non-zero for a
# reason other than a confirmed GraphQL error) -- prints the manual
# "resolve it yourself" instruction to stderr and exits non-zero, since
# there is no gh subcommand or REST fallback for resolving a review thread.
# Usage: aimi-cli.sh forge-resolve-review-thread --thread-id <id> [--project <path>]
cmd_forge_resolve_review_thread() {
  check_jq

  local thread_id="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --thread-id) shift; thread_id="${1:-}" ;;
      --project)   shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-resolve-review-thread: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$thread_id" ]; then
    echo "Usage: aimi-cli.sh forge-resolve-review-thread --thread-id <id> [--project <path>]" >&2
    exit 1
  fi

  # Fail-fast usage check BEFORE the thread id is ever passed to gh -- the
  # primary injection defense is the -f binding in the github adapter
  # above, not this pattern check.
  if ! [[ "$thread_id" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
    echo "Error: forge-resolve-review-thread: invalid --thread-id value: $thread_id" >&2
    exit 1
  fi

  local result status message
  result=$(_forge_resolve_review_thread "$thread_id")
  status=$(printf '%s' "$result" | jq -r '.status')

  if [ "$status" = "error" ]; then
    message=$(printf '%s' "$result" | jq -r '.message // "unknown error"')
    {
      echo "Warning: could not resolve this review thread automatically ($message)."
      echo "There is no automatic fallback once the forge CLI itself cannot run this -- resolve it manually in the pull/merge request's diff view (GitHub: Files changed; GitLab: Changes; Gitea/Forgejo: Files changed) and mark the conversation/thread resolved."
    } >&2
    printf '%s\n' "$result"
    exit 1
  fi

  printf '%s\n' "$result"
}

# Detect a Claude Design handoff bundle under a given root (defaults to CWD).
# Scans depth-1 subdirectories for a README.md containing the handoff marker.
# Returns JSON object when found, "null" when not found.
# With --all, returns a JSON array sorted newest-first (by directory mtime).
cmd_detect_design_bundle() {
  local root="" all=false json=false

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) shift; root="${1:-}" ;;
      --all)  all=true ;;
      --json) json=true ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
  done

  # Resolve scan root (default: CWD)
  local scan_root
  if [ -n "$root" ]; then
    # For relative paths, validate they stay within project boundary (prevents ../.. traversal).
    # Absolute paths are allowed as scan roots since this is a read-only operation.
    case "$root" in
      /*) : ;;  # Absolute path — skip boundary check (read-only scan)
      *)  validate_path_in_project "$root" ;;
    esac
    scan_root="$root"
  else
    scan_root="$(pwd)"
  fi

  if [ ! -d "$scan_root" ]; then
    echo "Error: Scan root does not exist: $scan_root" >&2
    exit 1
  fi

  # The handoff marker (fixed string, case-sensitive)
  local HANDOFF_MARKER='This is a **handoff bundle** from Claude Design (claude.ai/design).'

  # Collect matching bundles: each entry is "<mtime> <abspath>"
  local found_paths=()

  # Pre-check: scan_root may itself be a bundle directory. When its README has
  # the handoff marker, treat it as a single bundle and skip the children scan.
  local root_normalized="${scan_root%/}/"
  local root_readme="${root_normalized}README.md"
  if [ -f "$root_readme" ] && grep -qF "$HANDOFF_MARKER" "$root_readme"; then
    local root_mtime
    if command -v stat >/dev/null 2>&1; then
      root_mtime=$(stat -c '%Y' "$root_normalized" 2>/dev/null || stat -f '%m' "$root_normalized" 2>/dev/null || echo 0)
    else
      root_mtime=0
    fi
    found_paths+=("${root_mtime} ${root_normalized}")
  else
    for subdir in "${scan_root}"/*/; do
      [ -d "$subdir" ] || continue

      local base
      base=$(basename "$subdir")

      # Skip noise directories
      case "$base" in
        .worktrees|node_modules|.aimi|vendor) continue ;;
      esac

      local readme="${subdir}README.md"
      [ -f "$readme" ] || continue

      # Fixed-string, case-sensitive marker check
      grep -qF "$HANDOFF_MARKER" "$readme" || continue

      # Get directory mtime (seconds since epoch) — stat is not POSIX-portable;
      # use date-based approach via ls for mtime sorting, falling back to 0
      local mtime
      if command -v stat >/dev/null 2>&1; then
        # GNU stat (Linux) or BSD stat (macOS)
        mtime=$(stat -c '%Y' "$subdir" 2>/dev/null || stat -f '%m' "$subdir" 2>/dev/null || echo 0)
      else
        mtime=0
      fi

      found_paths+=("${mtime} ${subdir}")
    done
  fi

  # No bundles found
  if [ ${#found_paths[@]} -eq 0 ]; then
    echo "null"
    return 0
  fi

  # Sort found_paths by mtime descending (newest first)
  local sorted_paths
  sorted_paths=$(printf '%s\n' "${found_paths[@]}" | sort -rn)

  # Build JSON for a single bundle directory
  _build_bundle_json() {
    local subdir="$1"
    local base
    base=$(basename "$subdir")

    local readme="${subdir}README.md"
    local readme_rel="${base}/README.md"

    # chats[]: <bundle>/chats/*.md
    local chats_arr=()
    for f in "${subdir}chats/"*.md; do
      [ -f "$f" ] && chats_arr+=("${base}/chats/$(basename "$f")")
    done
    local chats_json
    if [ ${#chats_arr[@]} -gt 0 ]; then
      chats_json=$(printf '%s\n' "${chats_arr[@]}" | jq -R . | jq -s .)
    else
      chats_json="[]"
    fi

    # prototypes[]: <bundle>/project/**/*.html (recursive)
    local protos_arr=()
    if [ -d "${subdir}project" ]; then
      while IFS= read -r f; do
        [ -f "$f" ] && protos_arr+=("${base}/project/${f#${subdir}project/}")
      done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
    fi
    local protos_json
    if [ ${#protos_arr[@]} -gt 0 ]; then
      protos_json=$(printf '%s\n' "${protos_arr[@]}" | jq -R . | jq -s .)
    else
      protos_json="[]"
    fi

    # hasReact / hasTailwind: grep heuristics over prototype HTML and adjacent CSS
    local has_react=false has_tailwind=false
    if [ ${#protos_arr[@]} -gt 0 ]; then
      # Search the actual HTML files (absolute paths needed for grep)
      local abs_protos=()
      if [ -d "${subdir}project" ]; then
        while IFS= read -r f; do
          [ -f "$f" ] && abs_protos+=("$f")
        done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
      fi
      if [ ${#abs_protos[@]} -gt 0 ]; then
        if grep -qliF 'react' "${abs_protos[@]}" 2>/dev/null; then
          has_react=true
        fi
        if grep -qliF 'tailwind' "${abs_protos[@]}" 2>/dev/null; then
          has_tailwind=true
        fi
      fi
    fi

    # businessSpec / designSpec: case-insensitive discovery
    # (Claude Design exports occasionally produce camelCase filenames.)
    local business_spec="" design_spec=""
    local business_spec_file design_spec_file
    business_spec_file=$(find "${subdir}project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
    design_spec_file=$(find   "${subdir}project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
    [ -n "$business_spec_file" ] && business_spec="${base}/project/$(basename "$business_spec_file")"
    [ -n "$design_spec_file"   ] && design_spec="${base}/project/$(basename "$design_spec_file")"

    jq -n \
      --arg   path         "$base" \
      --arg   readme       "$readme_rel" \
      --argjson chats       "$chats_json" \
      --argjson prototypes  "$protos_json" \
      --argjson hasReact    "$has_react" \
      --argjson hasTailwind "$has_tailwind" \
      --arg   businessSpec "$business_spec" \
      --arg   designSpec   "$design_spec" \
      '{
        path:         $path,
        readme:       $readme,
        chats:        $chats,
        prototypes:   $prototypes,
        hasReact:     $hasReact,
        hasTailwind:  $hasTailwind,
        businessSpec: (if $businessSpec == "" then null else $businessSpec end),
        designSpec:   (if $designSpec   == "" then null else $designSpec   end)
      }'
  }

  if [ "$all" = true ]; then
    # Return all bundles as a JSON array, sorted newest-first
    local entries_json="[]"
    while IFS= read -r entry; do
      local subdir="${entry#* }"
      local bundle_json
      bundle_json=$(_build_bundle_json "$subdir")
      entries_json=$(echo "$entries_json" | jq --argjson b "$bundle_json" '. + [$b]')
    done <<< "$sorted_paths"
    echo "$entries_json"
  else
    # Return only the newest bundle
    local newest_entry
    newest_entry=$(echo "$sorted_paths" | head -1)
    local newest_subdir="${newest_entry#* }"
    _build_bundle_json "$newest_subdir"
  fi
}

# ============================================================================
# Bundle Prototype Helpers
# ============================================================================

# Compute a SHA-256 hex digest for a single file.
# Uses sha256sum (Linux) or shasum -a 256 (macOS), honoring _HAS_SHA256SUM.
# Usage: _hash_file <path>
# Prints: 64-char hex string
_hash_file() {
  local path="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

# Compute a deterministic composite SHA-256 over an ordered list of file paths.
# Sorts the paths before concatenating so the hash is stable across runs.
# Usage: _compute_composite_hash <file1> [<file2> ...]
# Prints: 64-char hex string
_compute_composite_hash() {
  local sorted_paths
  sorted_paths=$(printf "%s\n" "$@" | sort)
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | shasum -a 256 | awk '{print $1}'
  fi
}

# Compute a deterministic SHA-256 over all regular files in a directory tree.
# Files are sorted by path before concatenation for determinism.
# Usage: _hash_dir <dir>
# Prints: 64-char hex string, or empty string if dir is empty/missing
_hash_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf ""
    return 0
  fi
  local file_list
  file_list=$(find "$dir" -type f | sort)
  if [ -z "$file_list" ]; then
    printf ""
    return 0
  fi
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | shasum -a 256 | awk '{print $1}'
  fi
}

# Extract lines from a markdown file under a given top-level section heading.
# Matches /^## <N>\./ as the section start, reads until the next /^## [0-9]+\./ or EOF.
# Usage: _extract_markdown_section <file> <section_number>
# Prints: section body lines (stripped of the heading itself)
_extract_markdown_section() {
  local file="$1"
  local num="$2"
  awk -v n="$num" '
    /^## [0-9]+\./ {
      if (in_section) { exit }
      if ($0 ~ "^## " n "\\.") { in_section=1; next }
    }
    in_section { print }
  ' "$file"
}

# Parse bullet items from a markdown blob and return a JSON array.
# Each bullet (^- , ^* , or ^N. at the top level) is treated as one view entry.
# The view name is the first phrase up to the first colon, dash, or newline.
# Usage: _extract_view_list <markdown_text> <source_section>
# Prints: JSON array of {name, source_section} objects
_extract_view_list() {
  local text="$1"
  local source_section="$2"
  local json_array="[]"
  local name
  while IFS= read -r line; do
    # Match bullet: leading - , * , or digit followed by .
    case "$line" in
      [-*]\ *|[0-9]*.\ *)
        # Strip bullet prefix
        name="${line#[-*] }"
        name="${name#[0-9]*. }"
        # Trim to first colon or em-dash or plain dash
        name="${name%%:*}"
        name="${name%% -*}"
        name="${name%% —*}"
        # Trim leading/trailing whitespace via awk
        name=$(printf "%s" "$name" | awk '{$1=$1; print}')
        if [ -n "$name" ]; then
          json_array=$(printf "%s" "$json_array" | jq --arg n "$name" --arg s "$source_section" \
            '. + [{"name": $n, "source_section": $s}]')
        fi
        ;;
    esac
  done <<< "$text"
  printf "%s" "$json_array"
}

# Check bundle prototype generation status.
# Usage: aimi-cli.sh bundle-prototype-status --bundle <path> --topic <slug> [--force]
# Returns JSON with keys: needs_generation, view_list, view_source, output_path, sidecar_path
cmd_bundle_prototype_status() {
  local bundle_path="" topic_slug="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle) shift; bundle_path="${1:-}" ;;
      --topic)  shift; topic_slug="${1:-}" ;;
      --force)  force=true ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  if [ -z "$bundle_path" ]; then
    printf "Error: --bundle <path> is required\n" >&2; exit 1
  fi
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi

  # Bundle is a read-only input — allow absolute paths outside the project
  # (same pattern as cmd_detect_design_bundle --root).
  # Only the output paths (sidecar, html) must be within the project.
  if [ ! -d "$bundle_path" ]; then
    printf "Error: Bundle path does not exist or is not a directory: %s\n" "$bundle_path" >&2
    exit 1
  fi

  # Locate spec files inside the bundle (prefer bundle/project/ subdir)
  # Uses case-insensitive discovery so camelCase filenames are detected.
  local design_spec_path="" business_spec_path=""
  local _ds_proj _ds_root _bs_proj _bs_root
  _ds_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _ds_root=$(find "${bundle_path}"         -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _bs_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  _bs_root=$(find "${bundle_path}"         -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  if [ -n "$_ds_proj" ]; then
    design_spec_path="$_ds_proj"
  elif [ -n "$_ds_root" ]; then
    design_spec_path="$_ds_root"
  fi
  if [ -n "$_bs_proj" ]; then
    business_spec_path="$_bs_proj"
  elif [ -n "$_bs_root" ]; then
    business_spec_path="$_bs_root"
  fi

  # Derive output and sidecar paths — relative to the project root for portability.
  # AIMI_DIR is absolute after find_aimi_root(); strip PROJECT_ROOT prefix to get relative form.
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local output_path="${prototypes_dir}/${topic_slug}-bundle.html"
  local sidecar_path="${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate output paths stay within the project
  validate_path_in_project "${PROJECT_ROOT}/${output_path}"
  validate_path_in_project "${PROJECT_ROOT}/${sidecar_path}"

  # Compute current hashes
  local bundle_hash design_spec_hash business_spec_hash
  bundle_hash=$(_hash_dir "$bundle_path")
  if [ -n "$design_spec_path" ]; then
    design_spec_hash=$(_hash_file "$design_spec_path")
  else
    design_spec_hash=""
  fi
  if [ -n "$business_spec_path" ]; then
    business_spec_hash=$(_hash_file "$business_spec_path")
  else
    business_spec_hash=""
  fi

  # Extract view list: prefer DesignSpec § 4, fallback to BusinessSpec § 5 then § 6
  local view_list_json="[]"
  local view_source="none"

  if [ -n "$design_spec_path" ]; then
    local ds4
    ds4=$(_extract_markdown_section "$design_spec_path" "4")
    if [ -n "$ds4" ]; then
      local parsed
      parsed=$(_extract_view_list "$ds4" "designSpec § 4")
      local count
      count=$(printf "%s" "$parsed" | jq 'length')
      if [ "$count" -gt 0 ]; then
        view_list_json="$parsed"
        view_source="designSpec"
      fi
    fi
  fi

  if [ "$view_source" = "none" ] && [ -n "$business_spec_path" ]; then
    local bs5
    bs5=$(_extract_markdown_section "$business_spec_path" "5")
    if [ -n "$bs5" ]; then
      local parsed5
      parsed5=$(_extract_view_list "$bs5" "businessSpec § 5")
      local count5
      count5=$(printf "%s" "$parsed5" | jq 'length')
      if [ "$count5" -gt 0 ]; then
        view_list_json="$parsed5"
        view_source="businessSpec"
      fi
    fi

    if [ "$view_source" = "none" ]; then
      local bs6
      bs6=$(_extract_markdown_section "$business_spec_path" "6")
      if [ -n "$bs6" ]; then
        local parsed6
        parsed6=$(_extract_view_list "$bs6" "businessSpec § 6")
        local count6
        count6=$(printf "%s" "$parsed6" | jq 'length')
        if [ "$count6" -gt 0 ]; then
          view_list_json="$parsed6"
          view_source="businessSpec"
        fi
      fi
    fi
  fi

  # Determine needs_generation
  local needs_generation=false

  # If both specs are absent, view_source is none — no generation possible
  if [ "$view_source" = "none" ] && [ -z "$design_spec_path" ] && [ -z "$business_spec_path" ]; then
    needs_generation=false
  elif [ "$force" = "true" ]; then
    needs_generation=true
  elif [ ! -f "${PROJECT_ROOT}/${sidecar_path}" ]; then
    needs_generation=true
  else
    # Compare hashes from sidecar
    local sidecar_content
    sidecar_content=$(cat "${PROJECT_ROOT}/${sidecar_path}" 2>/dev/null || printf "{}")
    local sc_bundle sc_design sc_business
    sc_bundle=$(printf "%s" "$sidecar_content" | jq -r '.bundleHash // ""')
    sc_design=$(printf "%s" "$sidecar_content" | jq -r '.designSpecHash // ""')
    sc_business=$(printf "%s" "$sidecar_content" | jq -r '.businessSpecHash // ""')
    if [ "$sc_bundle" != "$bundle_hash" ] || \
       [ "$sc_design" != "$design_spec_hash" ] || \
       [ "$sc_business" != "$business_spec_hash" ]; then
      needs_generation=true
    fi
  fi

  jq -n \
    --argjson needs_generation "$needs_generation" \
    --argjson view_list "$view_list_json" \
    --arg view_source "$view_source" \
    --arg output_path "$output_path" \
    --arg sidecar_path "$sidecar_path" \
    '{
      needs_generation: $needs_generation,
      view_list: $view_list,
      view_source: $view_source,
      output_path: $output_path,
      sidecar_path: $sidecar_path
    }'
}

# Write the bundle-prototype sidecar atomically.
# Usage: aimi-cli.sh bundle-prototype-finalize \
#          --topic <slug> \
#          --bundle-hash <hex> \
#          --design-spec-hash <hex> \
#          --business-spec-hash <hex> \
#          --view-list <json-array> \
#          --source-command <brainstorm|plan>
cmd_bundle_prototype_finalize() {
  local topic_slug="" bundle_hash="" design_spec_hash="" business_spec_hash=""
  local view_list_json="" source_command=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --topic)              shift; topic_slug="${1:-}" ;;
      --bundle-hash)        shift; bundle_hash="${1:-}" ;;
      --design-spec-hash)   shift; design_spec_hash="${1:-}" ;;
      --business-spec-hash) shift; business_spec_hash="${1:-}" ;;
      --view-list)          shift; view_list_json="${1:-}" ;;
      --source-command)     shift; source_command="${1:-}" ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  # Validate required args
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi
  if [ -z "$source_command" ]; then
    printf "Error: --source-command <brainstorm|plan> is required\n" >&2; exit 1
  fi
  # Validate source-command value
  if [ "$source_command" != "brainstorm" ] && [ "$source_command" != "plan" ]; then
    printf "Error: --source-command must be exactly 'brainstorm' or 'plan', got: %s\n" "$source_command" >&2
    exit 1
  fi

  # Validate view-list is valid JSON array
  if [ -z "$view_list_json" ]; then
    view_list_json="[]"
  fi
  if ! printf "%s" "$view_list_json" | jq -e '. | arrays' >/dev/null 2>&1; then
    printf "Error: --view-list must be a valid JSON array\n" >&2; exit 1
  fi

  # Compute sidecar path — AIMI_DIR is absolute after find_aimi_root()
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local sidecar_path="${PROJECT_ROOT}/${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate path stays within project
  validate_path_in_project "$sidecar_path"

  # Ensure directory exists
  mkdir -p "$(dirname "$sidecar_path")"

  # Compute generatedAt timestamp
  local generated_at
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  # Build sidecar JSON
  local sidecar_json
  sidecar_json=$(jq -n \
    --arg generatedAt "$generated_at" \
    --arg bundleHash "$bundle_hash" \
    --arg designSpecHash "$design_spec_hash" \
    --arg businessSpecHash "$business_spec_hash" \
    --argjson viewList "$view_list_json" \
    --arg sourceCommand "$source_command" \
    '{
      generatedAt: $generatedAt,
      bundleHash: $bundleHash,
      designSpecHash: $designSpecHash,
      businessSpecHash: $businessSpecHash,
      viewList: $viewList,
      sourceCommand: $sourceCommand
    }')

  # Write atomically: write to tmp then mv
  local tmp_sidecar
  tmp_sidecar=$(mktemp "${sidecar_path}.XXXXXX")
  printf "%s\n" "$sidecar_json" > "$tmp_sidecar"
  chmod 600 "$tmp_sidecar"
  mv "$tmp_sidecar" "$sidecar_path"

  # Output confirmation JSON
  jq -n \
    --arg sidecar_path "$sidecar_path" \
    --arg generatedAt "$generated_at" \
    '{ written: $sidecar_path, generatedAt: $generatedAt }'
}

# Return the path to the OpenCode models validation cache file, keyed by mtime.
# Usage: _oc_models_cache_path <mtime>
# The cache stores the `opencode models` output for a specific models.json mtime.
_oc_models_cache_path() {
  local mtime="$1"
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-oc-cache-${mtime}.txt"
}

# Resolve which interactivity mode applies to the current shell.
# Prints exactly one of: picker, agent
#   agent  - AIMI_AGENT_MODE=true or CI=true (explicit overrides), OR no host
#            picker is available and stdin is not a TTY
#   picker - explicit host picker is available (Claude Code or OpenCode), OR
#            stdin is a TTY in a plain terminal
#
# Precedence (first match wins — explicit opt-out only):
#   1. --non-interactive flag → agent
#   2. AIMI_AGENT_MODE=true  → agent
#   3. CI=true               → agent
#   4. otherwise             → picker
#
# The old TTY-test branch ([ -t 0 ]) and the CLAUDECODE/OPENCODE_CONFIG_DIR
# host-check block are removed. A non-TTY shell is NOT a signal for agent mode;
# picker is the safe default so commands always surface Open Questions unless
# explicitly told not to.
cmd_detect_interactivity() {
  local non_interactive=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) non_interactive=1 ;;
    esac
    shift
  done
  if [ "$non_interactive" = "1" ] || [ "${AIMI_AGENT_MODE:-}" = "true" ] || [ "${CI:-}" = "true" ]; then
    echo "agent"
    return
  fi
  echo "picker"
}

# Resolve which configured model for each agent category.
# Reads ~/.config/aimi/models.json (schema v2.0) and maps each of the five
# categories (research, review, design, workflow, executor) to a concrete model ID.
# Schema v2.0 shape: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct one-level lookup: .categories[<host>][<category>] → model id.
# Always emits a single-line compact JSON object with all five keys.
# Unconfigured or fallback entries use the literal string "inherit".
# All warnings go to stderr; stdout is always valid JSON.
#
# v1.0 rejection: if the parsed JSON has a top-level .models key OR
# .schemaVersion is not "2.0", emits a stderr warning containing "schema 1.0"
# and returns the all-inherit fallback. Re-run `aimi-cli detect-models` to
# upgrade the config to v2.0.
#
# Performance notes:
#   - The standalone jq-empty validation pass is omitted; the resolution jq
#     error handler already catches malformed JSON.
#   - Multi-pass INVALID tagging is merged into a single jq invocation per host.
#   - OpenCode: `opencode models` output is cached by models.json mtime so
#     repeated calls within the same models.json state skip the shell-out.
cmd_resolve_models() {
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  # Fallback JSON — all five categories as inherit
  local _fallback='{"research":"inherit","review":"inherit","design":"inherit","workflow":"inherit","executor":"inherit"}'

  # No config file → silent fallback (preserves current behavior)
  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Read config (use read_aimi_models_config for consistent access)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: resolve-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # v1.0 rejection guard: reject any config that has a top-level .models key OR
  # whose .schemaVersion is not exactly "2.0". Both are signs of the old schema.
  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "Warning: resolve-models: schema 1.0 obsoleto — re-rode aimi-cli detect-models" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Determine host key
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  # Resolve each category via single-step lookup: .categories[$host][$cat] → model_id
  # Missing category or null value → inherit
  # The error handler catches malformed JSON (no separate jq empty pass needed).
  local _result
  _result=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    def resolve_cat($cat):
      ((.categories[$host][$cat] // null) | if . == null or . == "" then null else . end) as $model |
      if $model == null then "inherit" else $model end;
    {
      research: resolve_cat("research"),
      review:   resolve_cat("review"),
      design:   resolve_cat("design"),
      workflow: resolve_cat("workflow"),
      executor: resolve_cat("executor")
    } | @json
  ' 2>/dev/null) || {
    echo "Warning: resolve-models: models config file is malformed JSON or failed to parse: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  }

  if [ -z "$_result" ]; then
    echo "Warning: resolve-models: empty result from models config: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Validate resolved model IDs per host in a single jq pass:
  #   - invalid entries get value "INVALID\t<original>" (tab-delimited to handle = in model names)
  #   - warnings emitted via tab-delimited IFS read loop
  #   - validated result has INVALID entries replaced with "inherit"
  if _is_claude_code_host; then
    # Claude Code: exact-match against the set {opus, sonnet, haiku}.
    # The Task tool only accepts these short aliases — no version suffixes.
    local _tagged
    _tagged=$(printf '%s' "$_result" | jq -r '
      to_entries | map(
        .key as $cat |
        .value as $model |
        if $model == "inherit" then {key: $cat, value: "inherit"}
        elif ($model == "opus" or $model == "sonnet" or $model == "haiku") then
          {key: $cat, value: $model}
        else {key: $cat, value: ("INVALID\t" + $model)}
        end
      ) | from_entries | @json
    ' 2>/dev/null)

    # Emit warnings and build clean result in one pass
    local _validated
    _validated=$(printf '%s' "$_tagged" | jq -r '
      to_entries | map(
        if (.value | startswith("INVALID\t")) then {key: .key, value: "inherit"}
        else .
        end
      ) | from_entries | @json
    ' 2>/dev/null)

    # Print warnings for invalid entries (tab delimiter avoids = truncation)
    while IFS=$'\t' read -r _cat _val; do
      [ -n "$_cat" ] || continue
      echo "Warning: resolve-models: model '$_val' is not valid for Claude Code host (must be exactly opus, sonnet, or haiku; category: $_cat), falling back to inherit" >&2
    done < <(printf '%s' "$_tagged" | jq -r 'to_entries[] | select(.value | startswith("INVALID\t")) | .key + "\t" + (.value | ltrimstr("INVALID\t"))' 2>/dev/null)

    _result="$_validated"
  else
    # OpenCode: validate against `opencode models` output; skip validation when binary absent.
    # Cache the models list by models.json mtime to avoid shelling out on every call.
    if command -v opencode >/dev/null 2>&1; then
      local _config_mtime
      _config_mtime=$(stat -c '%Y' "$config_file" 2>/dev/null || stat -f '%m' "$config_file" 2>/dev/null || echo "0")
      local _oc_cache_file
      _oc_cache_file=$(_oc_models_cache_path "$_config_mtime")

      local _oc_models=""
      if [ -f "$_oc_cache_file" ]; then
        _oc_models=$(cat "$_oc_cache_file" 2>/dev/null) || _oc_models=""
      fi

      if [ -z "$_oc_models" ]; then
        _oc_models=$(opencode models 2>/dev/null) || _oc_models=""
        if [ -n "$_oc_models" ]; then
          # Write to cache (best-effort; failure is non-fatal)
          local _oc_aimi_dir
          _oc_aimi_dir=$(_aimi_config_dir)
          mkdir -p "$_oc_aimi_dir" 2>/dev/null || true
          printf '%s\n' "$_oc_models" > "$_oc_cache_file" 2>/dev/null || true
        fi
      fi

      if [ -n "$_oc_models" ]; then
        # Single jq pass: tag invalid entries with INVALID\t prefix
        local _oc_tagged
        _oc_tagged=$(printf '%s' "$_result" | jq -r --arg ocmodels "$_oc_models" '
          ($ocmodels | split("\n") | map(select(. != "")) | map(ltrimstr(" ") | rtrimstr(" "))) as $valid_list |
          to_entries | map(
            .key as $cat |
            .value as $model |
            if $model == "inherit" then {key: $cat, value: "inherit"}
            elif ($valid_list | index($model)) != null then {key: $cat, value: $model}
            else {key: $cat, value: ("INVALID\t" + $model)}
            end
          ) | from_entries | @json
        ' 2>/dev/null)

        local _oc_validated
        _oc_validated=$(printf '%s' "$_oc_tagged" | jq -r '
          to_entries | map(
            if (.value | startswith("INVALID\t")) then {key: .key, value: "inherit"}
            else .
            end
          ) | from_entries | @json
        ' 2>/dev/null)

        while IFS=$'\t' read -r _cat _val; do
          [ -n "$_cat" ] || continue
          echo "Warning: resolve-models: model '$_val' is not valid for OpenCode host (category: $_cat), falling back to inherit" >&2
        done < <(printf '%s' "$_oc_tagged" | jq -r 'to_entries[] | select(.value | startswith("INVALID\t")) | .key + "\t" + (.value | ltrimstr("INVALID\t"))' 2>/dev/null)

        _result="$_oc_validated"
      fi
      # If opencode models output is empty, skip validation and use configured values
    fi
    # If opencode binary is absent, skip validation (fail-safe: use configured value as-is)
  fi

  printf '%s\n' "$_result"
}

# Emit the current per-category model assignments for the active host.
# Shape: {"research": <id|null>, "review": <id|null>, "design": <id|null>,
#         "workflow": <id|null>, "executor": <id|null>}
# Unlike resolve-models, unset entries emit JSON null (not the string "inherit")
# so the /aimi:setup-models picker can distinguish "not configured" from a literal
# "inherit" override and pre-select sensible defaults.
# Schema v1.0 configs are rejected with the same stderr warning resolve-models emits;
# stdout falls back to all-null on rejection or any error.
cmd_get_current_models() {
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  local _fallback='{"research":null,"review":null,"design":null,"workflow":null,"executor":null}'

  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: get-current-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "Warning: get-current-models: schema 1.0 obsoleto — re-rode aimi-cli detect-models" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  local _result
  _result=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    def get_cat($cat):
      ((.categories[$host][$cat] // null) | if . == null or . == "" then null else . end);
    {
      research: get_cat("research"),
      review:   get_cat("review"),
      design:   get_cat("design"),
      workflow: get_cat("workflow"),
      executor: get_cat("executor")
    } | @json
  ' 2>/dev/null) || {
    echo "Warning: get-current-models: models config file is malformed JSON or failed to parse: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  }

  if [ -z "$_result" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  printf '%s\n' "$_result"
}

# List available models for the current host as a JSON array on stdout.
# Claude Code host: fixed array ["opus","sonnet","haiku"].
# OpenCode host: runs `opencode models` and parses its output into a JSON array.
#   Falls back to the built-in default Anthropic list when the opencode binary is absent,
#   printing one warning to stderr.
# stdout is always a valid JSON array; warnings go to stderr.
cmd_list_models() {
  check_jq

  local _models_list
  if _is_claude_code_host; then
    # Claude Code: short aliases only — the Task tool only accepts haiku/sonnet/opus
    printf '["opus","sonnet","haiku"]\n'
    return 0
  fi

  # OpenCode: query `opencode models`
  _models_list=""
  if command -v opencode >/dev/null 2>&1; then
    _models_list=$(opencode models 2>/dev/null) || _models_list=""
  fi

  if [ -z "${_models_list:-}" ]; then
    echo "Warning: list-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
    _models_list="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
  fi

  # Convert newline-delimited list to a JSON array
  printf '%s\n' "$_models_list" | jq -R . | jq -s .
}

# Detect available models on the current host and write ~/.config/aimi/models.json.
# Writes schema v2.0: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct category-to-model mapping — no tier indirection.
# On Claude Code (CLAUDECODE=1): fixed set — haiku, sonnet, opus (short aliases required by Task tool).
# On OpenCode: reads `opencode models`; falls back to a built-in default Anthropic list
#   with one warning when the opencode binary is absent.
#
# Flag mode (non-interactive write): when ANY of --research, --review, --design,
#   --workflow, --executor is provided, build and write models.json with the given
#   category-to-model assignments directly, skipping the TTY prompt. Preserves the
#   other host's categories sub-table when a pre-existing file exists.
#   --research <model>  Model id for the research category
#   --review <model>    Model id for the review category
#   --design <model>    Model id for the design category
#   --workflow <model>  Model id for the workflow category
#   --executor <model>  Model id for the executor category
#   All five flags must be supplied together.
#
# Interactive (stdin is a TTY, no category flags): prompts once per category for a
#   concrete model id, validated against the host's available-model list.
# Non-interactive (no flags, stdin is not TTY): writes sensible defaults without prompting.
# Writes atomically via write_aimi_models_config (mktemp + chmod 0600 + mv).
# NOTE: Only the current host's sub-table is written. Re-run on the other host to
#       populate both claudeCode and opencode tables.
cmd_detect_models() {
  check_jq

  # ---- Parse category flags --------------------------------------------------
  local _flag_research="" _flag_review="" _flag_design="" _flag_workflow="" _flag_executor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --research)
        shift
        _flag_research="${1:-}"
        ;;
      --review)
        shift
        _flag_review="${1:-}"
        ;;
      --design)
        shift
        _flag_design="${1:-}"
        ;;
      --workflow)
        shift
        _flag_workflow="${1:-}"
        ;;
      --executor)
        shift
        _flag_executor="${1:-}"
        ;;
      -*)
        echo "Error: detect-models: unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  # ---- Determine host key for models table ----------------------------------
  local _host_key
  if _is_claude_code_host; then
    _host_key="claudeCode"
  else
    _host_key="opencode"
  fi

  # ---- Flag mode: category flags provided → non-interactive write -----------
  if [ -n "$_flag_research" ] || [ -n "$_flag_review" ] || [ -n "$_flag_design" ] || [ -n "$_flag_workflow" ] || [ -n "$_flag_executor" ]; then
    # Require all five categories when using flag mode
    if [ -z "$_flag_research" ] || [ -z "$_flag_review" ] || [ -z "$_flag_design" ] || [ -z "$_flag_workflow" ] || [ -z "$_flag_executor" ]; then
      echo "Error: detect-models: when using category flags, all five must be provided: --research, --review, --design, --workflow, --executor" >&2
      exit 1
    fi

    # Read existing config to preserve the other host's categories sub-table
    local _existing_json
    _existing_json=$(read_aimi_models_config) || _existing_json=""

    local _models_json
    if [ -n "$_existing_json" ] && printf '%s' "$_existing_json" | jq empty 2>/dev/null; then
      # Merge: preserve other host's categories block, replace current host's block
      _models_json=$(printf '%s' "$_existing_json" | jq \
        --arg host_key  "$_host_key" \
        --arg research  "$_flag_research" \
        --arg review    "$_flag_review" \
        --arg design    "$_flag_design" \
        --arg workflow  "$_flag_workflow" \
        --arg executor  "$_flag_executor" \
        '{
          schemaVersion: "2.0",
          categories: ((.categories // {}) + {
            ($host_key): {
              research: $research,
              review:   $review,
              design:   $design,
              workflow: $workflow,
              executor: $executor
            }
          })
        }')
    else
      # No existing config or malformed — create fresh
      _models_json=$(jq -n \
        --arg host_key  "$_host_key" \
        --arg research  "$_flag_research" \
        --arg review    "$_flag_review" \
        --arg design    "$_flag_design" \
        --arg workflow  "$_flag_workflow" \
        --arg executor  "$_flag_executor" \
        '{
          schemaVersion: "2.0",
          categories: {
            ($host_key): {
              research: $research,
              review:   $review,
              design:   $design,
              workflow: $workflow,
              executor: $executor
            }
          }
        }')
    fi

    write_aimi_models_config "$_models_json"

    local _config_path
    _config_path=$(_aimi_models_config_path)
    printf 'detect-models: wrote %s table to %s\n' "$_host_key" "$_config_path" >&2
    printf 'detect-models: re-run on the other host to populate both claudeCode and opencode tables\n' >&2
    printf '%s\n' "$_models_json"
    return 0
  fi

  # ---- Available model sets per host ----------------------------------------
  local _available_models
  local _oc_absent=0

  if _is_claude_code_host; then
    # Claude Code: short aliases only — the Task tool only accepts haiku/sonnet/opus
    _available_models="haiku
sonnet
opus"
  else
    # OpenCode: query `opencode models`; fall back to built-in list if absent
    if command -v opencode >/dev/null 2>&1; then
      _available_models=$(opencode models 2>/dev/null) || _available_models=""
    fi
    if [ -z "${_available_models:-}" ]; then
      _oc_absent=1
      echo "Warning: detect-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
      _available_models="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
    fi
  fi

  # ---- Build per-category model defaults ------------------------------------
  # research → fast (haiku), review → powerful (opus),
  # design/workflow/executor → balanced (sonnet)
  local _fast_model _balanced_model _powerful_model

  _fast_model=$(printf '%s\n' "$_available_models" | grep -i "haiku" | head -1)
  [ -z "$_fast_model" ] && _fast_model=$(printf '%s\n' "$_available_models" | head -1)

  _balanced_model=$(printf '%s\n' "$_available_models" | grep -i "sonnet" | head -1)
  [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | sed -n '2p')
  [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | head -1)

  _powerful_model=$(printf '%s\n' "$_available_models" | grep -i "opus" | head -1)
  [ -z "$_powerful_model" ] && _powerful_model=$(printf '%s\n' "$_available_models" | tail -1)

  # Per-category defaults: research=fast, review=powerful, design/workflow/executor=balanced
  local _default_research="$_fast_model"
  local _default_review="$_powerful_model"
  local _default_design="$_balanced_model"
  local _default_workflow="$_balanced_model"
  local _default_executor="$_balanced_model"

  # ---- Per-category model assignment ----------------------------------------
  local _model_research="$_default_research"
  local _model_review="$_default_review"
  local _model_design="$_default_design"
  local _model_workflow="$_default_workflow"
  local _model_executor="$_default_executor"

  if [ -t 0 ]; then
    # stdin is a TTY — prompt once per category for a concrete model id
    local _prompt_models
    _prompt_models=$(printf '%s\n' "$_available_models" | tr '\n' '|' | sed 's/|$//')

    _prompt_category() {
      local cat="$1"
      local default="$2"
      local answer
      printf 'Category %s — model [%s] (default: %s): ' "$cat" "$_prompt_models" "$default" >&2
      read -r answer </dev/tty
      answer=$(printf '%s' "$answer" | tr -d '[:space:]')
      # Validate against available models; fall back to default on empty or invalid input
      if [ -z "$answer" ]; then
        printf '%s' "$default"
      elif printf '%s\n' "$_available_models" | grep -qxF "$answer"; then
        printf '%s' "$answer"
      else
        printf '%s' "$default"
      fi
    }

    _model_research=$(_prompt_category "research" "$_default_research")
    _model_review=$(_prompt_category "review"    "$_default_review")
    _model_design=$(_prompt_category "design"    "$_default_design")
    _model_workflow=$(_prompt_category "workflow"  "$_default_workflow")
    _model_executor=$(_prompt_category "executor"  "$_default_executor")
  fi

  # ---- Assemble the models.json document (v2.0 schema) ----------------------
  # Read the existing config FIRST so we preserve the other host's sub-table.
  # Without this merge, an unflagged detect-models invocation (e.g., the
  # /aimi:plan automatic resolve at the top of every command) overwrites the
  # file with only the current host's block, silently dropping the inactive
  # host's configured models. This is the same merge pattern the flag-mode
  # branch above uses (lines 2477-2502).
  local _existing_json
  _existing_json=$(read_aimi_models_config) || _existing_json=""

  local _models_json
  if [ -n "$_existing_json" ] && printf '%s' "$_existing_json" | jq empty 2>/dev/null; then
    # Merge: preserve other host's categories block, replace current host's block
    _models_json=$(printf '%s' "$_existing_json" | jq \
      --arg host_key  "$_host_key" \
      --arg research  "$_model_research" \
      --arg review    "$_model_review" \
      --arg design    "$_model_design" \
      --arg workflow  "$_model_workflow" \
      --arg executor  "$_model_executor" \
      '{
        schemaVersion: "2.0",
        categories: ((.categories // {}) + {
          ($host_key): {
            research: $research,
            review:   $review,
            design:   $design,
            workflow: $workflow,
            executor: $executor
          }
        })
      }')
  else
    # No existing config or malformed — create fresh
    _models_json=$(jq -n \
      --arg host_key  "$_host_key" \
      --arg research  "$_model_research" \
      --arg review    "$_model_review" \
      --arg design    "$_model_design" \
      --arg workflow  "$_model_workflow" \
      --arg executor  "$_model_executor" \
      '{
        schemaVersion: "2.0",
        categories: {
          ($host_key): {
            research: $research,
            review:   $review,
            design:   $design,
            workflow: $workflow,
            executor: $executor
          }
        }
      }')
  fi

  # ---- Atomic write ---------------------------------------------------------
  write_aimi_models_config "$_models_json"

  local _config_path
  _config_path=$(_aimi_models_config_path)
  printf 'detect-models: wrote %s table to %s\n' "$_host_key" "$_config_path" >&2
  printf 'detect-models: re-run on the other host to populate both claudeCode and opencode tables\n' >&2
  printf '%s\n' "$_models_json"
}

# Check whether the first-run model-selection prompt should be shown.
# Echoes exactly one token to stdout:
#   skip   — models.json already exists OR the marker file already exists
#   prompt — neither file exists (first run, not yet configured)
# No jq needed — pure file-existence checks.
cmd_models_prompt_check() {
  local config_file
  config_file=$(_aimi_models_config_path)

  # Missing config → prompt
  if [ ! -f "$config_file" ]; then
    echo "prompt"
    return 0
  fi

  # Empty/unreadable file → prompt (user should re-configure)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "prompt"
    return 0
  fi

  # v1.0 schema (has top-level .models OR schemaVersion != "2.0") → prompt
  # The picker re-writes the file in v2.0 shape on next configure.
  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "prompt"
    return 0
  fi

  # v2.0 with current host configured (at least one category non-null) → skip.
  # Aligns with get-current-models: if the picker would pre-fill nothing for
  # this host, ask the user instead of silently falling back to all-inherit.
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  local _has_config
  _has_config=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    (.categories[$host] // {}) as $h |
    [($h.research // null), ($h.review // null), ($h.design // null),
     ($h.workflow // null), ($h.executor // null)]
    | map(select(. != null and . != ""))
    | (length > 0)
  ' 2>/dev/null) || _has_config="false"

  if [ "$_has_config" = "true" ]; then
    echo "skip"
    return 0
  fi

  # Host not configured but config file is present — honor the per-host
  # dismissal marker if it exists. File-missing always re-prompts (above);
  # this branch only matters when the user kept some config but explicitly
  # opted out for this host.
  local marker_file
  marker_file=$(_aimi_models_prompt_marker_path)
  if [ -f "$marker_file" ]; then
    echo "skip"
  else
    echo "prompt"
  fi
}

# Atomically create the models first-run prompt marker file.
# Idempotent — safe to call when the marker already exists.
# Content: current date or a short sentinel line.
cmd_models_prompt_dismiss() {
  local marker_file
  marker_file=$(_aimi_models_prompt_marker_path)
  local marker_dir
  marker_dir=$(dirname "$marker_file")

  if ! mkdir -p "$marker_dir" 2>/dev/null; then
    echo "Error: models-prompt-dismiss: cannot create directory: $marker_dir" >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${marker_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf 'models-prompt-seen: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp_file"
  if ! mv "$tmp_file" "$marker_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: models-prompt-dismiss: mv failed for $marker_file" >&2
    return 1
  fi
  echo "models-prompt-dismiss: marker written to $marker_file"
}

# Setup branch: deterministic branch creation/checkout logic
# Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]
cmd_setup_branch() {
  local branch_name="" default_branch="" project_dir="" base_override=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --base)
        shift
        base_override="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security)
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch_name" >&2
    exit 1
  fi

  # Validate default branch name (security)
  if ! [[ "$default_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid default branch name: $default_branch" >&2
    exit 1
  fi

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid base branch name: $base_override" >&2
    exit 1
  fi

  # Get current branch (empty string means detached HEAD)
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")

  # Case 1: Already on target branch
  if [ "$current_branch" = "$branch_name" ]; then
    printf '{"branch":"%s","action":"already-on-branch"}\n' "$branch_name"
    return 0
  fi

  # Case 2: Target branch exists locally
  if git branch --list "$branch_name" | grep -q "$branch_name"; then
    git checkout "$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-local"}\n' "$branch_name"
    return 0
  fi

  # Case 3: Target branch exists on remote only
  if git ls-remote --heads origin "$branch_name" 2>/dev/null | grep -q "$branch_name"; then
    git checkout -b "$branch_name" "origin/$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-remote"}\n' "$branch_name"
    return 0
  fi

  # Case --base override: Branch is new and caller provided an explicit base.
  # The existence check stays here rather than in the shared resolver so this
  # hard failure keeps its exact stderr text and exit code regardless of how
  # the resolver's own "explicit-base" resolution behaves.
  if [ -n "$base_override" ]; then
    if ! git ls-remote --heads origin "$base_override" 2>/dev/null | grep -q "$base_override" && \
       ! git branch --list "$base_override" | grep -q "$base_override"; then
      echo "Error: Base branch does not exist: $base_override" >&2
      exit 1
    fi
  fi

  # Case 4/5: Branch is new — delegate the base decision to the shared
  # resolver (_resolve_branch_base) so this path can never drift from the
  # container path's resolve-base-branch. The mapping from reason to action
  # is total: explicit-base -> created-from-base, default-branch ->
  # created-from-default, detached-head and stacked-on-current both ->
  # created-from-current. target-exists is unreachable here — Case 1-3 above
  # already short-circuited on an existing target before the resolver runs.
  local resolution reason base
  resolution=$(_resolve_branch_base "$branch_name" "$default_branch" "$base_override")
  reason=$(echo "$resolution" | jq -r '.reason')
  base=$(echo "$resolution" | jq -r '.base')

  case "$reason" in
    explicit-base)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-base","base":"%s"}\n' "$branch_name" "$base_override"
      ;;
    default-branch)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-default"}\n' "$branch_name"
      ;;
    detached-head|stacked-on-current)
      # Create from current HEAD (detached or carrying unmerged work) without
      # an explicit ref, matching the pre-existing behavior exactly.
      git checkout -b "$branch_name" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-current"}\n' "$branch_name"
      ;;
    *)
      echo "Error: Unexpected base-resolution reason: $reason" >&2
      exit 1
      ;;
  esac
  return 0
}

# Decide what branch a new branch or container should be cut from, without
# performing any git mutation. Single source of truth shared by the inline
# (cmd_setup_branch) and container (execute.md) paths so an empty/unset base
# can never mean "stack on current" on one path and "use the default branch"
# on the other. Assumes branch_name/default_branch/base_override are already
# validated and CWD is inside the target git repository.
#
# Resolution order (first match wins):
#   1. base_override given                                -> explicit-base
#   2. branch_name already exists locally or on origin     -> target-exists
#   3. HEAD is detached                                     -> detached-head
#   4. current branch IS default, or merged into origin/default -> default-branch
#   5. otherwise (current branch carries unmerged work)     -> stacked-on-current
#
# The emitted "base" prefers the origin/<name> remote-tracking ref over the
# bare local name, so a container is never cut from a stale local ref after a
# successful fetch -- mirroring how cmd_setup_branch already checks out
# origin/$default_branch for created-from-default. Two reasons opt out:
#
#   stacked-on-current -- the candidate is the caller's own checkout, and
#     inheriting its local tip is what stacking means. Preferring origin here
#     drops every commit made since the last push.
#   detached-head      -- base is the raw HEAD sha; there is no branch name to
#     prefer a remote ref for.
#
# promptNeeded is true only when reason resolves to stacked-on-current --
# the same four-condition gate execute.md Step 1.6 computes inline today
# (target absent locally and on origin, current branch not default, current
# branch not merged into origin/default), now computed once per repo here.
# Exact ref predicates. Every one of these answers a yes/no question about a
# single, fully-qualified ref -- never a pattern plus a substring grep.
#
# `git branch --list X | grep -q X` and `git ls-remote --heads origin X` both
# match loosely: ls-remote patterns match on trailing path components, so a
# probe for `main` reports refs/heads/team/main and the caller then emits an
# origin/main that does not resolve, killing worktree creation in any repo
# that happens to carry a scoped branch of the same leaf name.
_local_has_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

_origin_has_branch() {
  git ls-remote --heads origin "refs/heads/$1" 2>/dev/null \
    | grep -q "[[:space:]]refs/heads/${1}$"
}

# Is <branch> already merged into origin/<default>?
#
# --format strips the "[* ] " column git normally prints, and -qxF matches the
# whole line literally. A regex match here is unsafe: git permits `.` in ref
# names, so a branch named feat.x matches a merged feat/x and its real
# unmerged work is discarded with no prompt -- the exact failure issue #78 is
# about, reached through a different door.
_is_merged_into_default() {
  git branch --format='%(refname:short)' --merged "origin/$2" 2>/dev/null \
    | grep -qxF "$1"
}

_resolve_branch_base() {
  local branch_name="$1" default_branch="$2" base_override="$3"
  local current_branch reason base candidate prompt_needed
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  base=""
  candidate=""
  prompt_needed=false

  if [ -n "$base_override" ]; then
    reason="explicit-base"
    candidate="$base_override"
  elif _local_has_branch "$branch_name" || _origin_has_branch "$branch_name"; then
    reason="target-exists"
    candidate="$branch_name"
  elif [ -z "$current_branch" ]; then
    reason="detached-head"
    base=$(git rev-parse HEAD 2>/dev/null || echo "")
  elif [ "$current_branch" = "$default_branch" ] || _is_merged_into_default "$current_branch" "$default_branch"; then
    reason="default-branch"
    candidate="$default_branch"
  else
    reason="stacked-on-current"
    candidate="$current_branch"
    prompt_needed=true
  fi

  # Origin preference, scoped by reason: prefer the origin/<name>
  # remote-tracking ref for a reference point the caller did not author, so a
  # container is never cut from a stale local ref after a successful fetch.
  #
  # stacked-on-current is deliberately excluded. There the candidate IS the
  # caller's own checkout, and inheriting its local tip is the entire point of
  # stacking -- preferring origin would silently drop every commit made since
  # the last push, which is the common state of an autonomous run. That would
  # also put this path back in disagreement with cmd_setup_branch, whose
  # stacked-on-current arm checks out from local HEAD.
  if [ -n "$candidate" ]; then
    if [ "$reason" != "stacked-on-current" ] && _origin_has_branch "$candidate"; then
      base="origin/$candidate"
    else
      base="$candidate"
    fi
  fi

  printf '{"base":"%s","reason":"%s","currentBranch":"%s","defaultBranch":"%s","promptNeeded":%s}\n' \
    "$base" "$reason" "$current_branch" "$default_branch" "$prompt_needed"
}

# CLI wrapper for _resolve_branch_base(): arg-parsing, --project cd and the
# three branch-name validations, mirroring cmd_setup_branch's shape exactly.
cmd_resolve_base_branch() {
  local branch_name="" default_branch="" project_dir="" base_override=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --base)
        shift
        base_override="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security)
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch_name" >&2
    exit 1
  fi

  # Validate default branch name (security)
  if ! [[ "$default_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $default_branch" >&2
    exit 1
  fi

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $base_override" >&2
    exit 1
  fi

  _resolve_branch_base "$branch_name" "$default_branch" "$base_override"
}

# Clear all state files (preserves tasks directory)
cmd_clear_state() {
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result" "$AIMI_DIR/cli-path"
  rm -f "$AIMI_DIR"/default-branch-* 2>/dev/null
  rm -f "$AIMI_DIR"/.state.lock "$AIMI_DIR"/*.lock 2>/dev/null
  rmdir "$AIMI_DIR"/*.lock.d 2>/dev/null || true
  echo "State cleared."
}

# Print the plugin version from plugin.json
cmd_version() {
  local script_path plugin_json
  script_path="${BASH_SOURCE[0]:-$0}"
  plugin_json="$(cd "$(dirname "$script_path")/.." && pwd)/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo "Error: plugin.json not found" >&2
    exit 1
  fi
  jq -r '.version' "$plugin_json"
}

# Check CLI version staleness
# Compares stored cli-path against the glob-resolved latest path
# Flags: --quiet (suppress stderr), --fix (auto-fix stale detection)
cmd_check_version() {
  local quiet=false fix=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=true ;;
      --fix)   fix=true ;;
      *)       break ;;
    esac
    shift
  done

  local stored_path latest_path stored_version latest_version
  local config_dir
  config_dir=$(_claude_config_dir)

  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
    printf '{"status":"ok","path":"%s/scripts/aimi-cli.sh","message":"managed by compound-plugin converter"}\n' "$plugin_dir"
    return 0
  fi

  # Resolve the latest installed path via glob
  latest_path=$(ls "$config_dir"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  # Case: glob returns empty — no installed version found
  if [ -z "$latest_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No installed aimi-cli.sh found via glob." >&2
    fi
    jq -n '{status: "unknown", message: "No installed version found"}'
    return 0
  fi

  latest_version=$(_extract_version_from_path "$latest_path")

  # Read stored path from state
  stored_path=$(read_state "cli-path")

  # Case: .aimi/cli-path does not exist — missing is not stale
  if [ -z "$stored_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No stored cli-path found. Run init-session to persist." >&2
    fi
    jq -n --arg ver "$latest_version" --arg path "$latest_path" \
      '{status: "missing", latestVersion: $ver, latestPath: $path}'
    return 0
  fi

  stored_version=$(_extract_version_from_path "$stored_path")

  # Case: stored path matches latest — current
  if [ "$stored_path" = "$latest_path" ]; then
    printf '{"status":"current","version":"%s"}\n' "$stored_version"
    return 0
  fi

  # Case: stored path differs — stale
  if [ "$fix" = true ]; then
    write_state "cli-path" "$latest_path"
    write_global_cli_cache "$latest_path"
    jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
      '{status: "fixed", storedVersion: $sv, latestVersion: $lv}'
    return 0
  fi

  if [ "$quiet" = false ]; then
    echo "Warning: CLI version is stale. Stored: $stored_version, Latest: $latest_version" >&2
  fi
  jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
       --arg sp "$stored_path" --arg lp "$latest_path" \
    '{status: "stale", storedVersion: $sv, latestVersion: $lv, storedPath: $sp, latestPath: $lp}'
  return 1
}

# Remove old cached plugin version directories, keeping only the latest
# Scans <config_dir>/plugins/cache/*/aimi-engineering/*/ for version dirs
# Outputs JSON {"removed":<count>,"kept":"<version>"} to stdout
cmd_cleanup_versions() {
  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
    printf '{"removed":0,"skipped":true,"message":"converter manages lifecycle"}\n'
    return 0
  fi

  local latest_path latest_version latest_version_dir
  local removed=0
  local config_dir
  config_dir=$(_claude_config_dir)

  # Resolve the latest installed path via glob
  latest_path=$(ls "$config_dir"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  # No installed versions found
  if [ -z "$latest_path" ]; then
    jq -n '{removed: 0, kept: null}'
    return 0
  fi

  latest_version=$(_extract_version_from_path "$latest_path")
  # .../aimi-engineering/1.4.0/scripts/aimi-cli.sh -> .../aimi-engineering/1.4.0
  latest_version_dir=$(dirname "$(dirname "$latest_path")")

  # Iterate all version directories under all marketplace cache entries
  local version_dir
  for version_dir in "$config_dir"/plugins/cache/*/aimi-engineering/*/; do
    # Strip trailing slash for clean comparison
    version_dir="${version_dir%/}"

    # Skip if this is the latest version directory
    if [ "$version_dir" = "$latest_version_dir" ]; then
      continue
    fi

    # Skip if not actually a directory (glob might not expand)
    if [ ! -d "$version_dir" ]; then
      continue
    fi

    # Attempt removal; log warning and continue on failure
    if rm -rf "$version_dir" 2>/dev/null; then
      removed=$((removed + 1))
    else
      echo "Warning: Failed to remove $version_dir" >&2
    fi
  done

  # Update cli-path state to point to the latest version
  write_state "cli-path" "$latest_path"
  write_global_cli_cache "$latest_path"

  jq -n --argjson removed "$removed" --arg kept "$latest_version" \
    '{removed: $removed, kept: $kept}'
}

# Prime the global CLI path cache explicitly.
# Used by install hooks and slash commands to populate the cache without relying
# on the lazy-resolution layers.
#
# JSON output: {status, path, host, version, message}
#   status: 'ok' | 'already_current' | 'not_found' | 'error'
#   path:   absolute path written (or null)
#   host:   'claude_code' | 'opencode'
#   version: semver extracted from path (or null)
#   message: optional human-readable string
#
# Exit codes: 0 for ok/already_current/not_found, 1 for error
cmd_prime_cache() {
  local host_label
  local resolved_path=""
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)

  # Determine host
  if _is_claude_code_host; then
    host_label="claude_code"
  elif [ -n "$plugin_dir" ]; then
    host_label="opencode"
  else
    # Neither CLAUDECODE=1 nor AIMI_PLUGIN_DIR set — try Claude Code glob anyway
    host_label="claude_code"
  fi

  # ---- Resolve path ----
  if [ "$host_label" = "opencode" ]; then
    # OpenCode branch: AIMI_PLUGIN_DIR is set and CLAUDECODE is unset
    local candidate="$plugin_dir/scripts/aimi-cli.sh"
    if [ ! -x "$candidate" ]; then
      jq -n --arg msg "AIMI_PLUGIN_DIR/scripts/aimi-cli.sh is not executable: $candidate" \
        '{status:"error",path:null,host:"opencode",version:null,message:$msg}'
      return 1
    fi
    # Validate: must be exactly $plugin_dir/scripts/aimi-cli.sh (no traversal)
    if [ "$candidate" != "$plugin_dir/scripts/aimi-cli.sh" ]; then
      jq -n --arg msg "Path rejected: does not match expected OpenCode pattern" \
        '{status:"error",path:null,host:"opencode",version:null,message:$msg}'
      return 1
    fi
    resolved_path="$candidate"
  else
    # Claude Code branch: glob for latest installed path
    local config_dir
    config_dir=$(_claude_config_dir)
    resolved_path=$(bash -c "ls \"$config_dir\"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1")

    if [ -z "$resolved_path" ]; then
      if [ -z "${AIMI_PLUGIN_DIR:-}" ]; then
        jq -n '{status:"not_found",path:null,host:"claude_code",version:null,message:"Plugin not installed. Run /plugin install aimi-engineering first."}'
        return 0
      fi
    fi

    # Validate path matches expected pattern
    case "$resolved_path" in
      */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
        : # valid
        ;;
      *)
        jq -n --arg path "$resolved_path" \
          '{status:"error",path:null,host:"claude_code",version:null,message:"Resolved path rejected: does not match expected cache pattern"}'
        return 1
        ;;
    esac

    # Verify executable
    if [ ! -x "$resolved_path" ]; then
      jq -n --arg path "$resolved_path" \
        '{status:"error",path:null,host:"claude_code",version:null,message:"Resolved path is not executable"}'
      return 1
    fi
  fi

  # ---- Already-current check ----
  local existing_cache
  existing_cache=$(read_global_cli_cache)
  if [ -n "$existing_cache" ] && [ "$existing_cache" = "$resolved_path" ]; then
    local ver
    ver=$(_extract_version_from_path "$resolved_path")
    jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$ver" \
      '{status:"already_current",path:$path,host:$host,version:$ver,message:"Cache already points to this path"}'
    return 0
  fi

  # ---- Write cache ----
  local write_error
  if ! write_error=$(write_global_cli_cache "$resolved_path" 2>&1); then
    jq -n --arg host "$host_label" --arg msg "write_global_cli_cache failed: $write_error" \
      '{status:"error",path:null,host:$host,version:null,message:$msg}'
    return 1
  fi

  local ver
  ver=$(_extract_version_from_path "$resolved_path")
  jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$ver" \
    '{status:"ok",path:$path,host:$host,version:$ver,message:"Cache primed successfully"}'
  return 0
}

# Pass a gate on a story
# Usage: gate-pass US-NNN [--option 'value']
cmd_gate_pass() {
  local story_id="$1"
  shift || true
  local option=""

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-pass <story-id> [--option 'value']" >&2
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --option)
        option="${2:-}"
        if [ -z "$option" ]; then
          echo '{"valid":false,"errors":["--option requires a value"]}'
          exit 1
        fi
        shift 2
        ;;
      *)
        echo "{\"valid\":false,\"errors\":[\"Unknown flag: $1\"]}"
        exit 1
        ;;
    esac
  done

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Verify story has a gate field
  local has_gate
  has_gate=$(jq --arg id "$story_id" '[.userStories[] | select(.id == $id) | .gate] | length' "$tasks_file")
  if [ "$has_gate" -eq 0 ] || [ "$(jq --arg id "$story_id" '.userStories[] | select(.id == $id) | .gate' "$tasks_file")" = "null" ]; then
    echo '{"valid":false,"errors":["Story '"$story_id"' has no gate defined"]}'
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    if [ -n "$option" ]; then
      jq --arg id "$story_id" --arg option "$option" \
        '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed", selectedOption: $option}' \
        "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
    else
      jq --arg id "$story_id" \
        '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed"}' \
        "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
    fi
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" '.userStories[] | select(.id == $id) | {id, gate}' "$tasks_file"
}

# Fail a gate on a story
cmd_gate_fail() {
  local story_id="$1"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-fail <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Verify story has a gate field
  local has_gate
  has_gate=$(jq --arg id "$story_id" '[.userStories[] | select(.id == $id) | .gate] | length' "$tasks_file")
  if [ "$has_gate" -eq 0 ] || [ "$(jq --arg id "$story_id" '.userStories[] | select(.id == $id) | .gate' "$tasks_file")" = "null" ]; then
    echo '{"valid":false,"errors":["Story '"$story_id"' has no gate defined"]}'
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "failed"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" '.userStories[] | select(.id == $id) | {id, gate}' "$tasks_file"
}

# Update a nested field on a story
# Usage: update-field US-NNN field.path value
# Supports dotted paths like "verification.status"
cmd_update_field() {
  local story_id="$1"
  local field_path="$2"
  local value="$3"

  if [ -z "$story_id" ] || [ -z "$field_path" ] || [ -z "$value" ]; then
    echo "Usage: aimi-cli.sh update-field <story-id> <field.path> <value>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Build jq path from dotted notation (e.g., "verification.status" -> .verification.status)
  # IFS-split on a herestring is trailing-newline-safe; avoids read returning non-zero
  # on the final unterminated segment when piping through sed, which dropped the leaf.
  local jq_path _parts _p
  IFS=. read -ra _parts <<< "$field_path"
  jq_path=''
  for _p in "${_parts[@]}"; do
    jq_path+=".$_p"
  done

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" --arg val "$value" \
      "(.userStories[] | select(.id == \$id) | ${jq_path}) = \$val" \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" ".userStories[] | select(.id == \$id) | {id, ${field_path%%.*}}" "$tasks_file"
}

# Validate waves: compute waves from dependsOn, compare to stored wave, report mismatches
cmd_validate_waves() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  jq '
    . as $root |
    ($root.userStories | map({(.id): (.dependsOn // [])}) | add // {}) as $deps |
    ($root.userStories | map(.id)) as $all_ids |

    # Compute waves iteratively
    # Wave 0: stories with no dependencies
    # Wave N: stories whose deps are all in waves < N
    (
      reduce range($all_ids | length) as $iteration (
        {};
        . as $assigned |
        ($all_ids | map(select(. as $id | $assigned | has($id) | not))) as $remaining |
        reduce $remaining[] as $id (
          $assigned;
          . as $current |
          if (($deps[$id] // []) | length == 0) then
            $current + {($id): 0}
          elif (($deps[$id] // []) | all(. as $d | $current | has($d))) then
            (($deps[$id] // []) | map($current[.]) | max + 1) as $wave |
            $current + {($id): $wave}
          else
            $current
          end
        )
      )
    ) as $computed |

    # Compare computed waves against stored wave fields
    [
      $root.userStories[] |
      . as $story |
      ($computed[$story.id] // null) as $computed_wave |
      ($story.wave // null) as $stored_wave |
      select(
        ($computed_wave != null and $stored_wave != null and $computed_wave != $stored_wave) or
        ($computed_wave != null and $stored_wave == null)
      ) |
      {
        id: $story.id,
        storedWave: $stored_wave,
        computedWave: $computed_wave
      }
    ] as $mismatches |

    if ($mismatches | length) == 0 then
      {valid: true, errors: []}
    else
      {valid: false, errors: [$mismatches[] | "Wave mismatch: \(.id) stored=\(.storedWave) computed=\(.computedWave)"]}
    end
  ' "$tasks_file"
}

# Validate tasks file citation fields
# For schemaVersion >= 3.3: validates DesignSpec verbatim citations for visual stories
# For schemaVersion < 3.3: emits skip-info to stderr and exits 0
# stdout: {valid, errors[]} JSON; exits non-zero when invalid
cmd_validate_tasks() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  # ONE jq process for every scalar metadata field this function reads, rather
  # than one process per field. This is a process-count fix, not an I/O fix:
  # measured on this repo, a jq process costs ~18ms to start and ~1ms to read a
  # 46KB tasks file, so eight separate reads of the same document paid ~8x the
  # startup and bought nothing. Batching them costs one startup (~20ms) and cuts
  # roughly 140ms off every validate-tasks invocation.
  #
  # EVERY FIELD USES `// ""`, NEVER `// empty` -- and that is load-bearing rather
  # than stylistic. `empty` emits NO field at all when the value is absent, which
  # shifts every following field one position left and assigns each variable its
  # neighbour's value. Nothing would error; the wrong branchName would simply be
  # validated against the wrong pattern. `// ""` always emits exactly one field
  # per position, and the shell restores "absent" semantics by testing for the
  # empty string -- which is what every consumer below already did.
  #
  # THE DELIMITER IS \037 (ASCII unit separator), NOT THE TAB @tsv EMITS, AND
  # THAT SUBSTITUTION IS THE WHOLE CORRECTNESS ARGUMENT. `read` splits on IFS,
  # but a tab is IFS *whitespace*, and bash collapses runs of IFS whitespace
  # into a single delimiter -- so two adjacent empty fields (the common case
  # here: no designBundle, no execution) silently vanish and every later value
  # lands in the wrong variable. `// ""` keeps jq's output aligned; `IFS=$'\t'
  # read` then throws that alignment away. \037 is not whitespace, so bash
  # preserves every empty field exactly where it was.
  #
  # @tsv is still what produces the fields, because it escapes \t, \n, \r and \\
  # inside each value -- so no value can contain a literal newline that would
  # truncate `read`, nor a literal tab that would survive the tr below as a
  # spurious separator. The tr is one ~2ms process; the seven jq processes it
  # helps remove cost ~126ms.
  local schema_version design_spec_rel prototype_count frontend_only
  local business_spec_rel execution_mode has_phase branch_name
  local _vt_meta _vt_probe
  _vt_meta=$(jq -r '[
    (.metadata.schemaVersion // .schemaVersion // "0"),
    (.metadata.designBundle.designSpec // ""),
    (.metadata.prototypePaths | if type == "array" then length else 0 end | tostring),
    ((.metadata.frontendOnly // false) | tostring),
    (.metadata.designBundle.businessSpec // ""),
    (.metadata.execution // ""),
    (if (.metadata.phase // null) != null then "true" else "false" end),
    (.metadata.branchName // "")
  ] | @tsv' "$tasks_file" 2>/dev/null | tr '\t' '\037')

  if [ -n "$_vt_meta" ]; then
    IFS=$'\037' read -r schema_version design_spec_rel prototype_count frontend_only \
      business_spec_rel execution_mode has_phase branch_name _vt_probe <<< "$_vt_meta"
    # The assertion is on what the SHELL parsed, never on what jq emitted --
    # the bug this replaces passed a jq-side field count while the shell-side
    # split had already dropped two fields. `_vt_probe` is a ninth name with no
    # ninth field to receive it: `read` leaves it empty when the split produced
    # exactly 8, and non-empty only if a future edit adds fields without adding
    # variables. schema_version is separately required to be non-empty, which is
    # what catches a split that produced too FEW.
    if [ -n "$_vt_probe" ] || [ -z "$schema_version" ]; then
      echo "validate-tasks: internal error: metadata read did not split into 8 fields" >&2
      return 1
    fi
  fi
  # An unreadable or malformed tasks file leaves every field empty, exactly as
  # each individual `jq ... 2>/dev/null` did before.
  schema_version="${schema_version:-}"

  # Compare versions: below 3.3 → skip with info message
  # Use sort -V to determine version ordering
  if [ "$(printf '%s\n' "$schema_version" "3.3" | sort -V | head -n1)" != "3.3" ]; then
    echo "skipping citation validation (schemaVersion ${schema_version} pre-dates citation enforcement)" >&2
    return 0
  fi

  # Collect errors as a bash array
  local errors=()

  # DesignSpec scan: only when metadata.designBundle.designSpec is non-null
  # AND metadata.prototypePaths is non-empty
  # design_spec_rel and prototype_count come from the batched metadata read above.
  prototype_count="${prototype_count:-0}"

  if [ -n "$design_spec_rel" ] && [ "$prototype_count" -gt 0 ]; then
    # Resolve DesignSpec path relative to PROJECT_ROOT
    local design_spec_path
    design_spec_path="${PROJECT_ROOT}/${design_spec_rel}"

    if [ ! -f "$design_spec_path" ]; then
      errors+=("${tasks_file}: DesignSpec file not found: ${design_spec_rel}")
    else
      # Extract visual stories: id + acceptanceCriteria entries as TSV lines
      # Format: <story_id>\t<ac_index>\t<ac_text>
      local visual_ac_data
      visual_ac_data=$(jq -r '
        .userStories[] |
        select(.verification.strategy == "visual") |
        . as $s |
        .acceptanceCriteria | to_entries[] |
        [$s.id, (.key | tostring), .value] | @tsv
      ' "$tasks_file" 2>/dev/null)

      if [ -n "$visual_ac_data" ]; then
        # Process each AC entry
        while IFS=$'\t' read -r story_id ac_index ac_text; do
          [ -z "$story_id" ] && continue

          # Extract all "literal" (DesignSpec § N.N L<line>) patterns from the AC
          # Pattern: "some literal" (DesignSpec § N.N L<line>)
          # Use grep to find all matches in the ac_text
          local matches
          matches=$(printf '%s' "$ac_text" | grep -oE '"[^"]+" \(DesignSpec § [0-9]+\.[0-9]+ L[0-9]+\)' 2>/dev/null || true)

          [ -z "$matches" ] && continue

          while IFS= read -r match; do
            [ -z "$match" ] && continue

            # Extract the literal string (between double quotes)
            local literal section line_num
            literal=$(printf '%s' "$match" | sed 's/^"\(.*\)" (DesignSpec § .*)$/\1/')
            section=$(printf '%s' "$match" | grep -oE '§ [0-9]+\.[0-9]+' | sed 's/§ //')
            line_num=$(printf '%s' "$match" | grep -oE 'L[0-9]+' | head -1 | sed 's/L//')

            # Locate subsection in DesignSpec and check verbatim presence
            if ! _validate_designspec_citation "$design_spec_path" "$literal" "$section"; then
              errors+=("${tasks_file}: ${story_id} AC[${ac_index}]: missing DesignSpec citation for \"${literal}\" in section § ${section}")
            fi
          done <<< "$matches"
        done <<< "$visual_ac_data"
      fi
    fi
  fi

  # BusinessSpec scan: only when metadata.frontendOnly is true AND metadata.designBundle.businessSpec is non-null
  # frontend_only and business_spec_rel come from the batched metadata read above.
  if [ "$frontend_only" = "true" ] && [ -n "$business_spec_rel" ]; then
    # Resolve BusinessSpec path relative to PROJECT_ROOT
    local business_spec_path
    business_spec_path="${PROJECT_ROOT}/${business_spec_rel}"

    if [ ! -f "$business_spec_path" ]; then
      errors+=("${tasks_file}: BusinessSpec file not found: ${business_spec_rel}")
    else
      # Iterate every endpoints[] entry
      local endpoint_count
      endpoint_count=$(jq '.metadata.backendSpec.endpoints | if type == "array" then length else 0 end' "$tasks_file" 2>/dev/null)
      endpoint_count="${endpoint_count:-0}"

      local ep_index=0
      while [ "$ep_index" -lt "$endpoint_count" ]; do
        # Get source value for this endpoint
        local ep_source
        ep_source=$(jq -r --argjson idx "$ep_index" '.metadata.backendSpec.endpoints[$idx].source // empty' "$tasks_file" 2>/dev/null)

        if [ -z "$ep_source" ]; then
          errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}]: missing source field")
          ep_index=$((ep_index + 1))
          continue
        fi

        # Check if source uses derived: prefix
        if printf '%s' "$ep_source" | grep -q '^derived:'; then
          # Warn to stderr, do not add to errors
          printf '%s: backendSpec.endpoints[%s]: derived source — manual review required\n' \
            "$tasks_file" "$ep_index" >&2
          ep_index=$((ep_index + 1))
          continue
        fi

        # Validate literal source format: "BusinessSpec § N[.N] L<line>"
        if ! printf '%s' "$ep_source" | grep -qE '^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$'; then
          errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}]: malformed source \"${ep_source}\" (expected 'BusinessSpec § N[.N] L<line>' or 'derived: ...')")
          ep_index=$((ep_index + 1))
          continue
        fi

        # Extract section from source
        local ep_section
        ep_section=$(printf '%s' "$ep_source" | grep -oE '§ [0-9]+(\.[0-9]+)?' | sed 's/§ //')

        # Iterate every field in responseShape
        local field_names
        field_names=$(jq -r --argjson idx "$ep_index" \
          '.metadata.backendSpec.endpoints[$idx].responseShape | if type == "object" then keys[] else empty end' \
          "$tasks_file" 2>/dev/null)

        while IFS= read -r field_name; do
          [ -z "$field_name" ] && continue

          # Get per-field source if it exists (responseShape field can be {type, source} or a scalar)
          local field_source
          field_source=$(jq -r --argjson idx "$ep_index" --arg fn "$field_name" \
            '.metadata.backendSpec.endpoints[$idx].responseShape[$fn] | if type == "object" then .source // empty else empty end' \
            "$tasks_file" 2>/dev/null)

          # If field has its own source, validate it too
          if [ -n "$field_source" ]; then
            if printf '%s' "$field_source" | grep -q '^derived:'; then
              printf '%s: backendSpec.endpoints[%s].responseShape.%s: derived source — manual review required\n' \
                "$tasks_file" "$ep_index" "$field_name" >&2
              continue
            fi
            if ! printf '%s' "$field_source" | grep -qE '^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$'; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: malformed source \"${field_source}\"")
              continue
            fi
            # Use the field-level section for subsection lookup
            local field_section
            field_section=$(printf '%s' "$field_source" | grep -oE '§ [0-9]+(\.[0-9]+)?' | sed 's/§ //')
            if ! _validate_businessspec_field "$business_spec_path" "$field_name" "$field_section"; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: field name not found in BusinessSpec § ${field_section}")
            fi
          else
            # No per-field source: check field name against the endpoint-level cited section
            if ! _validate_businessspec_field "$business_spec_path" "$field_name" "$ep_section"; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: field name not found in BusinessSpec § ${ep_section}")
            fi
          fi
        done <<< "$field_names"

        ep_index=$((ep_index + 1))
      done
    fi
  fi

  # metadata.execution validation: optional discriminator, must be exactly
  # "container" or "inline" when present. Absent is valid (defaults to inline
  # for backward compatibility with every tasks.json written before this field
  # existed) — see commands/references/execution-mode.md for the read contract.
  # execution_mode comes from the batched metadata read above.
  if [ -n "$execution_mode" ] && [ "$execution_mode" != "container" ] && [ "$execution_mode" != "inline" ]; then
    errors+=("${tasks_file}: metadata.execution has invalid value \"${execution_mode}\" (expected \"container\" or \"inline\")")
  fi

  # metadata.execution / metadata.phase mutual exclusivity: a phase-scoped
  # file (metadata.phase present) always executes inside its own phase
  # container, so metadata.execution would be dead data there — the exact
  # confusion US-006 corrects. /aimi:plan never writes both; this rule
  # catches a hand-edited or stale file that carries both anyway.
  # has_phase comes from the batched metadata read above.
  if [ "$has_phase" = "true" ] && [ -n "$execution_mode" ]; then
    errors+=("${tasks_file}: metadata.execution and metadata.phase cannot both be present (phase-scoped files never carry metadata.execution)")
  fi

  # metadata.branchName validation: must match the same mandated pattern
  # already enforced by cmd_init_session and open-pr.md (see CLAUDE.md's
  # Security Requirements) — branchName is interpolated into git/gh commands
  # downstream, so a value outside this charset is a command-injection vector.
  # An absent/empty value also fails, since the pattern requires a leading
  # alphanumeric character.
  # branch_name comes from the batched metadata read above.
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    errors+=("${tasks_file}: metadata.branchName \"${branch_name}\" does not match the required pattern ^[a-zA-Z0-9][a-zA-Z0-9/_-]*\$")
  fi

  # verification.url charset validation: a conservative allowlist (letters,
  # digits, and :/?#@!&*+,._~%=- , first character alphanumeric or /) that
  # excludes backtick, $, quotes, ;, |, <, >, and whitespace — the characters
  # needed for shell command injection when a URL is later interpolated into
  # a quoted string (see I10 review finding). Stories without a verification
  # object, or with a null/empty/non-string url, are ignored — same tolerance
  # the metadata.execution check above gives to an absent field.
  local url_charset_re='^[A-Za-z0-9/][A-Za-z0-9:/?#@!&*+,._~%=-]*$'
  local bad_urls
  bad_urls=$(jq -r --arg re "$url_charset_re" '
    .userStories[] |
    select(.verification | type == "object") |
    select((.verification.url | type == "string") and (.verification.url != "")) |
    select((.verification.url | test($re)) | not) |
    [.id, .verification.url] | @tsv
  ' "$tasks_file" 2>/dev/null)

  if [ -n "$bad_urls" ]; then
    while IFS=$'\t' read -r story_id bad_url; do
      [ -z "$story_id" ] && continue
      errors+=("${tasks_file}: ${story_id} verification.url \"${bad_url}\" contains characters outside the allowed charset")
    done <<< "$bad_urls"
  fi

  # Emit result JSON
  if [ ${#errors[@]} -eq 0 ]; then
    echo '{"valid": true, "errors": []}'
    return 0
  else
    # Build JSON errors array
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
    printf '{"valid": false, "errors": %s}\n' "$errors_json"
    return 1
  fi
}

# Helper: validate that a literal string appears verbatim in the cited DesignSpec subsection.
# Subsection boundary: lines from "## N.N <heading>" (or "### N.N") to next heading of equal/higher level.
# Normalizes Unicode quotes, em-dashes, non-breaking spaces, and HTML entities on both sides.
# Usage: _validate_designspec_citation <spec_file> <literal> <section>
# Returns 0 if found, 1 if not found.
_validate_designspec_citation() {
  local spec_file="$1"
  local literal="$2"
  local section="$3"

  # Normalize a string: Unicode quotes → ASCII, em-dash → hyphen,
  # non-breaking space → space, HTML entities to literal chars.
  _normalize_text() {
    local text="$1"
    # Curly double quotes → straight double quote
    text=$(printf '%s' "$text" | sed \
      -e 's/\xe2\x80\x9c/"/g' \
      -e 's/\xe2\x80\x9d/"/g' \
      -e "s/\xe2\x80\x98/'/g" \
      -e "s/\xe2\x80\x99/'/g" \
      -e 's/\xe2\x80\x94/-/g' \
      -e 's/\xc2\xa0/ /g' \
      -e 's/&amp;/\&/g' \
      -e 's/&nbsp;/ /g' \
      -e 's/&lt;/</g' \
      -e 's/&gt;/>/g' \
      -e 's/&quot;/"/g')
    printf '%s' "$text"
  }

  # Determine heading level for section N.N (always "##" — subsection level)
  # Section like "3.1" is a sub-heading; we look for "## 3.1" or "### 3.1" etc.
  # We scan for the section heading and collect lines until the next equal/higher heading.

  local normalized_literal
  normalized_literal=$(_normalize_text "$literal")

  # Extract subsection body from the spec file
  # Strategy: use awk to find the heading containing the section number,
  # then collect lines until a heading of equal or higher level.
  local subsection_body
  subsection_body=$(awk -v section="$section" '
    BEGIN { in_section = 0; heading_level = 0 }
    {
      # Detect markdown headings: count leading # characters
      if (/^#+[[:space:]]/) {
        level = 0
        line_copy = $0
        while (substr(line_copy, 1, 1) == "#") {
          level++
          line_copy = substr(line_copy, 2)
        }
        # Check if this heading contains the section number
        if (!in_section) {
          # Look for pattern like "§ N.N" or "N.N " at start of heading text
          heading_text = substr($0, level + 1)
          # Strip leading spaces
          gsub(/^[[:space:]]+/, "", heading_text)
          if (heading_text ~ ("^(§[[:space:]]*)?" section "([[:space:]]|$)") || \
              heading_text ~ ("§[[:space:]]*" section "([[:space:]]|$)")) {
            in_section = 1
            heading_level = level
            next
          }
        } else {
          # We are in the section — stop at equal or higher level heading
          if (level <= heading_level) {
            exit
          }
        }
      }
      if (in_section) {
        print $0
      }
    }
  ' "$spec_file")

  if [ -z "$subsection_body" ]; then
    # Section not found in spec — treat as missing
    return 1
  fi

  # Normalize the subsection body
  local normalized_body
  normalized_body=$(_normalize_text "$subsection_body")

  # Check if normalized literal is a substring of normalized body
  if printf '%s' "$normalized_body" | grep -qF "$normalized_literal"; then
    return 0
  fi
  return 1
}

# Helper: validate that a field name appears as a literal substring in the cited BusinessSpec subsection.
# Reuses the same subsection-boundary algorithm as _validate_designspec_citation.
# Usage: _validate_businessspec_field <spec_file> <field_name> <section>
# Returns 0 if found, 1 if not found.
_validate_businessspec_field() {
  local spec_file="$1"
  local field_name="$2"
  local section="$3"

  # Extract subsection body from the spec file using the same awk strategy
  local subsection_body
  subsection_body=$(awk -v section="$section" '
    BEGIN { in_section = 0; heading_level = 0 }
    {
      if (/^#+[[:space:]]/) {
        level = 0
        line_copy = $0
        while (substr(line_copy, 1, 1) == "#") {
          level++
          line_copy = substr(line_copy, 2)
        }
        if (!in_section) {
          heading_text = substr($0, level + 1)
          gsub(/^[[:space:]]+/, "", heading_text)
          if (heading_text ~ ("^(§[[:space:]]*)?" section "([[:space:]]|$)") || \
              heading_text ~ ("§[[:space:]]*" section "([[:space:]]|$)")) {
            in_section = 1
            heading_level = level
            next
          }
        } else {
          if (level <= heading_level) {
            exit
          }
        }
      }
      if (in_section) {
        print $0
      }
    }
  ' "$spec_file")

  if [ -z "$subsection_body" ]; then
    return 1
  fi

  # Check if field name appears as a literal substring in the subsection body
  if printf '%s' "$subsection_body" | grep -qF "$field_name"; then
    return 0
  fi
  return 1
}

# Check whether a tasks file's stories are ALL terminal (completed or skipped)
# and non-empty. Echoes nothing; return code only (0 = archivable-as-a-file).
_archivable_file_is_terminal() {
  local tasks_file="$1"
  local non_terminal
  non_terminal=$(jq '[.userStories[] | select(.status != "completed" and .status != "skipped")] | length' "$tasks_file" 2>/dev/null)
  [ -z "$non_terminal" ] && return 1
  [ "$non_terminal" -ne 0 ] && return 1

  local total
  total=$(jq '.userStories | length' "$tasks_file" 2>/dev/null)
  [ -z "$total" ] && return 1
  [ "$total" -eq 0 ] && return 1
  return 0
}

# List task files where all stories have terminal status (completed or skipped).
# Discovers both the flat layout (.aimi/tasks/*-tasks.json) and the nested
# phase-folder layout (.aimi/tasks/<feature>/phase-N-slug/<feature>-phase-N-
# tasks.json) via the shared discovery helper. A feature folder's nested
# phase tasks files surface together as a single unit -- only when every
# phase tasks file discovered under that feature is all-terminal AND the
# feature's roadmap.json (read directly via jq, not a roadmap-lifecycle
# subcommand, to avoid coupling to its still-evolving CLI surface) marks
# every phase completed -- rather than piecemeal as each phase happens to
# finish. "completed" is the only terminal phase status (see the roadmap
# status enum in cmd_roadmap_set_status); there is no "deferred" status. A
# phase stuck in verification_failed therefore excludes its feature from the
# result same as any other non-completed status, but is never a *silent*
# dead end: it's called out on stderr each time, naming the feature and the
# blocked phase ids, so the block stays discoverable instead of an
# unexplained permanent absence from the list. A feature folder with no
# roadmap.json (or a malformed one) falls back to the flat per-file terminal
# check, so stray nested files created without roadmap-init are still
# individually archivable.
# Returns a JSON array of file paths (stdout shape unchanged by the above).
cmd_list_archivable() {
  local all_files
  all_files=$(_find_tasks_files_all)

  local result="["
  local first=true

  _archivable_append() {
    local resolved
    resolved=$(resolve_path "$1")
    if [ "$first" = true ]; then
      first=false
    else
      result="$result,"
    fi
    result="$result$(printf '"%s"' "$resolved")"
  }

  # Split discovered files into flat (direct child of TASKS_DIR) vs nested
  # (feature/phase-slug/file, two directories below TASKS_DIR).
  local flat_files=() nested_files=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$(dirname "$f")" = "$TASKS_DIR" ]; then
      flat_files+=("$f")
    else
      nested_files+=("$f")
    fi
  done <<< "$all_files"

  for f in "${flat_files[@]+"${flat_files[@]}"}"; do
    [ -f "$f" ] || continue
    _archivable_file_is_terminal "$f" && _archivable_append "$f"
  done

  # Group nested files by feature folder (two directories above each file)
  # and evaluate the whole feature as a unit.
  local -A feature_seen
  for f in "${nested_files[@]+"${nested_files[@]}"}"; do
    local feature_dir
    feature_dir=$(dirname "$(dirname "$f")")
    [ -n "${feature_seen[$feature_dir]:-}" ] && continue
    feature_seen[$feature_dir]=1

    local feature_files=()
    local ff
    for ff in "${nested_files[@]+"${nested_files[@]}"}"; do
      if [ "$(dirname "$(dirname "$ff")")" = "$feature_dir" ]; then
        feature_files+=("$ff")
      fi
    done

    local all_terminal=true
    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      if [ ! -f "$ff" ] || ! _archivable_file_is_terminal "$ff"; then
        all_terminal=false
        break
      fi
    done
    [ "$all_terminal" = true ] || continue

    local roadmap_path="$feature_dir/roadmap.json"
    if [ -f "$roadmap_path" ] && jq -e . "$roadmap_path" >/dev/null 2>&1; then
      local non_terminal_phases
      non_terminal_phases=$(jq '[.phases[] | select(.status != "completed")] | length' "$roadmap_path" 2>/dev/null)
      [ -z "$non_terminal_phases" ] && continue
      if [ "$non_terminal_phases" -ne 0 ]; then
        # A stuck (verification_failed) phase is excluded the same as any
        # other non-completed status, but never silently -- name it and the
        # feature on stderr every run so the block stays visible instead of
        # becoming an unexplained permanent absence from the result.
        local stuck_ids
        stuck_ids=$(jq -r '[.phases[] | select(.status == "verification_failed") | (.id|tostring)] | join(", ")' "$roadmap_path" 2>/dev/null)
        if [ -n "$stuck_ids" ]; then
          echo "Warning: list-archivable: $feature_dir not archivable -- phase(s) $stuck_ids stuck in verification_failed (re-verify via roadmap-set-status, or resolve manually)" >&2
        fi
        continue
      fi
    fi
    # No roadmap.json (or malformed): every discovered phase file already
    # passed the per-file terminal check above, so fall back to including them.

    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      _archivable_append "$ff"
    done
  done

  result="$result]"
  echo "$result"
}

# Archive a task file (and linked brainstorm) to .aimi/archive/
# Usage: archive-task <path>
cmd_archive_task() {
  local task_path="$1"

  if [ -z "$task_path" ]; then
    echo "Usage: aimi-cli.sh archive-task <path>" >&2
    exit 1
  fi

  # Resolve and validate path
  if [ ! -f "$task_path" ]; then
    echo "Error: Task file not found: $task_path" >&2
    exit 1
  fi

  local resolved_task
  resolved_task=$(resolve_path "$task_path")
  validate_path_in_project "$resolved_task"

  # Verify all stories are terminal
  local non_terminal
  non_terminal=$(jq '[.userStories[] | select(.status != "completed" and .status != "skipped")] | length' "$resolved_task" 2>/dev/null)
  if [ -z "$non_terminal" ] || [ "$non_terminal" -ne 0 ]; then
    echo "Error: Task file has non-terminal stories — cannot archive" >&2
    exit 1
  fi

  # Create archive directory
  local archive_dir="$AIMI_DIR/archive"
  mkdir -p "$archive_dir"

  # Helper: move a file to archive with collision handling
  # Usage: _archive_move <source_path>
  # Outputs the destination path
  _archive_move() {
    local src="$1"
    local basename
    basename=$(basename "$src")
    local dest="$archive_dir/$basename"

    if [ ! -e "$dest" ]; then
      mv "$src" "$dest"
      printf '%s' "$dest"
      return
    fi

    # Handle collision: append -N suffix before extension
    local name_no_ext ext
    # Split on first dot for files like foo-tasks.json
    name_no_ext="${basename%%.*}"
    ext="${basename#"$name_no_ext"}"  # includes leading dot(s)

    local n=2
    while true; do
      dest="$archive_dir/${name_no_ext}-${n}${ext}"
      if [ ! -e "$dest" ]; then
        mv "$src" "$dest"
        printf '%s' "$dest"
        return
      fi
      n=$((n + 1))
    done
  }

  # Move the task file
  local archived_task
  archived_task=$(_archive_move "$resolved_task")

  # Move companion .lock file if it exists
  if [ -f "${resolved_task}.lock" ]; then
    _archive_move "${resolved_task}.lock" > /dev/null
  fi

  # Move linked brainstorm if specified in metadata
  local brainstorm_path archived_brainstorm=""
  brainstorm_path=$(jq -r '.metadata.brainstormPath // empty' "$archived_task" 2>/dev/null)

  if [ -n "$brainstorm_path" ]; then
    # Resolve relative to project root
    local resolved_brainstorm
    if [ "${brainstorm_path#/}" = "$brainstorm_path" ]; then
      # Relative path — resolve from project root
      resolved_brainstorm="$PROJECT_ROOT/$brainstorm_path"
    else
      resolved_brainstorm="$brainstorm_path"
    fi

    # Validate brainstorm path stays within project root
    if [ -e "$resolved_brainstorm" ]; then
      validate_path_in_project "$resolved_brainstorm"
      archived_brainstorm=$(_archive_move "$resolved_brainstorm")
    fi
  fi

  # Delete linked research files (ephemeral — rm -f, not archived)
  local research_cleaned=0
  while IFS= read -r rpath; do
    [ -z "$rpath" ] && continue
    local resolved_research
    if [ "${rpath#/}" = "$rpath" ]; then
      # Relative path — resolve from project root
      resolved_research="$PROJECT_ROOT/$rpath"
    else
      resolved_research="$rpath"
    fi
    validate_path_in_project "$resolved_research"
    if [ -e "$resolved_research" ]; then
      rm -f "$resolved_research"
      research_cleaned=$((research_cleaned + 1))
    fi
  done < <(jq -r '.metadata.researchPaths[]? // empty' "$archived_task" 2>/dev/null)

  # Delete linked prototype files (ephemeral — rm -f, not archived)
  local prototype_cleaned=0
  while IFS= read -r ppath; do
    [ -z "$ppath" ] && continue
    local resolved_prototype
    if [ "${ppath#/}" = "$ppath" ]; then
      # Relative path — resolve from project root
      resolved_prototype="$PROJECT_ROOT/$ppath"
    else
      resolved_prototype="$ppath"
    fi
    validate_path_in_project "$resolved_prototype"
    if [ -e "$resolved_prototype" ]; then
      rm -f "$resolved_prototype"
      prototype_cleaned=$((prototype_cleaned + 1))
    fi
  done < <(jq -r '.metadata.prototypePaths[]? // empty' "$archived_task" 2>/dev/null)

  # Output result as JSON
  jq -n --arg task "$archived_task" \
    --arg brainstorm "${archived_brainstorm:-}" \
    --argjson researchCleaned "$research_cleaned" \
    --argjson prototypeCleaned "$prototype_cleaned" \
    '{archived: {task: $task, brainstorm: (if $brainstorm == "" then null else $brainstorm end), researchCleaned: $researchCleaned, prototypeCleaned: $prototypeCleaned}}'
}

# Usage: research-lookup [--ignore-missing-cited-paths] <path>
# Check whether a research file is fresh relative to its cited source paths.
# Freshness: research-file mtime >= newest mtime among existing cited source paths.
# A cited path that does not exist -> stale (logs a warning to stderr).
#   With --ignore-missing-cited-paths: missing cited paths log a warning but do NOT mark stale.
# No '## File References' section -> stale.
# Fresh: prints the research path + exits 0.
# Stale/undecidable: prints nothing + exits 1.
# Missing argument: usage on stderr + exits 1.
cmd_research_lookup() {
  local ignore_missing=0
  local research_path=""

  # Parse flag in either position relative to the positional path arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignore-missing-cited-paths)
        ignore_missing=1
        shift
        ;;
      -*)
        echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
        exit 1
        ;;
      *)
        research_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$research_path" ]; then
    echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
    exit 1
  fi

  if [ ! -f "$research_path" ]; then
    echo "Error: Research file not found: $research_path" >&2
    exit 1
  fi

  # Resolve and validate the research file path
  local resolved_research
  resolved_research=$(resolve_path "$research_path")
  validate_path_in_project "$resolved_research"

  # Get the mtime (seconds since epoch) of the research file
  local research_mtime
  research_mtime=$(stat -c '%Y' "$resolved_research" 2>/dev/null || stat -f '%m' "$resolved_research" 2>/dev/null)
  if [ -z "$research_mtime" ]; then
    echo "Error: Cannot stat research file: $resolved_research" >&2
    exit 1
  fi

  # Extract the '## File References' section: lines between the h2 header and the next h2/EOF
  # Parse bullet list entries (lines starting with - or *)
  local file_refs_section
  file_refs_section=$(awk '
    /^## File References/ { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$resolved_research")

  # If no File References section found -> stale
  if [ -z "$file_refs_section" ]; then
    exit 1
  fi

  # Parse bullet list: lines starting with optional whitespace then - or *
  # Extract the path portion (strip leading bullet marker and whitespace)
  local cited_paths
  cited_paths=$(printf '%s\n' "$file_refs_section" | grep -E '^\s*[-*]\s+' | sed 's/^\s*[-*]\s\+//')

  # If section exists but has no bullet entries -> stale
  if [ -z "$cited_paths" ]; then
    exit 1
  fi

  local newest_source_mtime=0
  local stale=0

  while IFS= read -r cited_path; do
    [ -z "$cited_path" ] && continue

    # Reject absolute paths outright
    if [ "${cited_path#/}" != "$cited_path" ]; then
      echo "Warning: Absolute path rejected in File References: $cited_path" >&2
      stale=1
      continue
    fi

    # Resolve relative to PROJECT_ROOT, canonicalizing any .. traversals
    local abs_cited_path
    if [ "$_HAS_REALPATH" -eq 1 ]; then
      # realpath -m normalizes .. without requiring the path to exist
      abs_cited_path=$(realpath -m "$PROJECT_ROOT/$cited_path" 2>/dev/null) || abs_cited_path="$PROJECT_ROOT/$cited_path"
    else
      abs_cited_path="$PROJECT_ROOT/$cited_path"
    fi

    # Validate stays within project (exit on escape attempt)
    validate_path_in_project "$abs_cited_path"

    # Check existence
    if [ ! -e "$abs_cited_path" ]; then
      echo "Warning: Cited source path does not exist (stale): $cited_path" >&2
      if [ "$ignore_missing" -eq 0 ]; then
        stale=1
      fi
      continue
    fi

    # Get mtime of the source file
    local src_mtime
    src_mtime=$(stat -c '%Y' "$abs_cited_path" 2>/dev/null || stat -f '%m' "$abs_cited_path" 2>/dev/null)
    if [ -z "$src_mtime" ]; then
      echo "Warning: Cannot stat cited path (stale): $abs_cited_path" >&2
      stale=1
      continue
    fi

    if [ "$src_mtime" -gt "$newest_source_mtime" ]; then
      newest_source_mtime=$src_mtime
    fi
  done <<< "$cited_paths"

  # If any cited path was missing or unreadable -> stale
  if [ "$stale" -ne 0 ]; then
    exit 1
  fi

  # Freshness check: research mtime must be >= newest source mtime
  if [ "$research_mtime" -ge "$newest_source_mtime" ]; then
    printf '%s\n' "$resolved_research"
    exit 0
  else
    exit 1
  fi
}

# Usage: extract-sections <file> --anchors "<heading titles, newline-separated>"
# Print only the requested '## '/'### ' sections of a research .md file, concatenated
# verbatim in the order the anchors were requested.
# Each section spans from its matching heading line up to (but not including) the next
# heading of the same-or-higher level, or EOF -- so an h2 anchor includes its nested h3s
# and stops at the next h2 (or h1); an h3 anchor stops at the next h3/h2 (or h1).
# Anchor text is matched case-insensitively against the heading text (leading #s and
# surrounding whitespace stripped). An anchor with no matching heading is skipped (not
# a fatal error) but is named in a "no section matched anchor" warning on stderr; a run
# whose anchors match nothing prints empty output, still exit 0.
# Anchors containing shell metacharacters ($ ` " \) are rejected with a warning on
# stderr and skipped -- defense in depth, since anchor text originates from untrusted
# research-file heading content.
# Path confinement mirrors research-lookup: resolve_path + validate_path_in_project.
# Missing file -> error + exit 1. Missing <file>/--anchors arg -> usage + exit 1.
cmd_extract_sections() {
  local file_path=""
  local anchors_raw=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --anchors)
        if [ $# -lt 2 ]; then
          echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
          exit 1
        fi
        anchors_raw="$2"
        shift 2
        ;;
      -*)
        echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
        exit 1
        ;;
      *)
        file_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$file_path" ] || [ -z "$anchors_raw" ]; then
    echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
    exit 1
  fi

  if [ ! -f "$file_path" ]; then
    echo "Error: File not found: $file_path" >&2
    exit 1
  fi

  # Resolve and validate the target file path
  local resolved_file
  resolved_file=$(resolve_path "$file_path")
  validate_path_in_project "$resolved_file"

  # Split --anchors on newlines only (comma is valid heading-text punctuation and must
  # NOT be treated as a delimiter); trim and lowercase each entry; skip blanks.
  # Extract each anchor's section (first matching heading only) in request order.
  local anchor anchor_lc unmatched_anchors=""
  while IFS= read -r anchor; do
    anchor=$(printf '%s' "$anchor" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$anchor" ] && continue

    # Defense in depth: anchors originate from untrusted research-file heading text.
    # The orchestrator sanitizes before interpolating, but this CLI must not rely on
    # that. Reject only characters dangerous inside a double-quoted shell argument --
    # &, comma, parens, colon, slash, hyphen, underscore, period, and single-quote are
    # all legitimate heading punctuation and MUST keep working.
    case "$anchor" in
      *'$'*|*'`'*|*'"'*|*'\'*)
        echo "Warning: anchor rejected (shell metacharacter): $anchor" >&2
        continue ;;
    esac

    anchor_lc=$(printf '%s' "$anchor" | tr '[:upper:]' '[:lower:]')

    # awk streams matched section lines straight to stdout (byte-for-byte, blank
    # lines and all) and reports match status via its own exit code -- this avoids
    # a $(...) capture, which would silently swallow trailing blank lines.
    if awk -v target="$anchor_lc" '
      BEGIN { in_section = 0; match_level = 0; matched_done = 0; in_fence = 0 }
      {
        if ($0 ~ /^[[:space:]]*(```|~~~)/) { in_fence = !in_fence }
        level = 0
        if (!in_fence && $0 ~ /^#+[[:space:]]/) {
          line_copy = $0
          while (substr(line_copy, 1, 1) == "#") {
            level++
            line_copy = substr(line_copy, 2)
          }
        }

        # Close the active section at the next heading of same-or-higher level
        # (a lower heading level number outranks a higher one, e.g. h2 outranks h3).
        if (in_section && level > 0 && level <= match_level) {
          in_section = 0
        }

        # Only ## / ### headings are matchable anchors; first match wins.
        if (!in_section && !matched_done && (level == 2 || level == 3)) {
          heading_text = substr($0, level + 1)
          gsub(/^[[:space:]]+/, "", heading_text)
          gsub(/[[:space:]]+$/, "", heading_text)
          if (tolower(heading_text) == target) {
            in_section = 1
            matched_done = 1
            match_level = level
          }
        }

        if (in_section) {
          print
        }
      }
      END { exit (matched_done ? 0 : 1) }
    ' "$resolved_file"; then
      :
    else
      unmatched_anchors="$unmatched_anchors
$anchor"
    fi
  done < <(printf '%s\n' "$anchors_raw")

  if [ -n "$unmatched_anchors" ]; then
    while IFS= read -r anchor; do
      [ -z "$anchor" ] && continue
      echo "Warning: no section matched anchor: $anchor" >&2
    done <<< "$unmatched_anchors"
  fi

  return 0
}

# Usage: research-gc
# Garbage-collect orphaned research files from .aimi/research/*.md.
# A file is deleted only when BOTH conditions are true:
#   1. It is NOT referenced by any active .aimi/tasks/*.json metadata.researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter foundationProposalPath.
#   2. Its mtime is older than 30 days.
# .aimi/archive is ignored entirely.
# Prints "Cleaned <N> orphaned research files (>30 days)" when N>0; silent when N=0.
cmd_research_gc() {
  local research_dir="$AIMI_DIR/research"

  # Nothing to do if research dir doesn't exist
  if [ ! -d "$research_dir" ]; then
    return 0
  fi

  # Build the referenced-set: union of researchPaths across all active tasks/*.json
  # plus researchPaths from all brainstorms/*.md frontmatter.
  local referenced_set=""

  # --- Source 1: .aimi/tasks/*.json metadata.researchPaths ---
  local tasks_dir="$AIMI_DIR/tasks"
  if [ -d "$tasks_dir" ]; then
    while IFS= read -r rpath; do
      [ -z "$rpath" ] && continue
      # Normalize: strip leading ./ and collapse to a canonical relative path
      rpath="${rpath#./}"
      referenced_set="$referenced_set
$rpath"
    done < <(
      for f in "$tasks_dir"/*.json; do
        [ -f "$f" ] || continue
        jq -r '.metadata.researchPaths[]? // empty' "$f" 2>/dev/null
      done
    )
  fi

  # --- Source 2: .aimi/brainstorms/*.md frontmatter researchPaths ---
  # --- Source 3: .aimi/brainstorms/*.md frontmatter foundationProposalPath (scalar) ---
  local brainstorms_dir="$AIMI_DIR/brainstorms"
  if [ -d "$brainstorms_dir" ]; then
    for bfile in "$brainstorms_dir"/*.md; do
      [ -f "$bfile" ] || continue
      # Extract YAML frontmatter (lines between opening and closing ---)
      # Parse researchPaths: list entries (lines starting with - under that key)
      # and foundationProposalPath: as a single scalar value, independent of order.
      local in_front=0 past_open=0 in_rp=0
      while IFS= read -r line; do
        if [ "$past_open" -eq 0 ] && [ "$line" = "---" ]; then
          past_open=1
          in_front=1
          continue
        fi
        if [ "$in_front" -eq 1 ] && [ "$line" = "---" ]; then
          break
        fi
        if [ "$in_front" -eq 0 ]; then
          # First non-frontmatter line without opening --- means no frontmatter
          break
        fi
        # Inside frontmatter
        if printf '%s\n' "$line" | grep -qE '^researchPaths\s*:'; then
          in_rp=1
          continue
        fi
        if printf '%s\n' "$line" | grep -qE '^foundationProposalPath[[:space:]]*:'; then
          # New top-level key: exit any in-progress researchPaths list scan first,
          # regardless of whether foundationProposalPath appears before or after it.
          in_rp=0
          local fp_entry
          # POSIX [[:space:]] (not \s — GNU-only in sed); then normalize the
          # extracted scalar so a YAML-quoted value or a trailing comment cannot
          # defeat the referenced-set match (which would delete a live artifact):
          #   1. strip a trailing " #comment" (space-hash onward)
          #   2. strip one pair of surrounding double or single quotes
          #   3. strip a leading ./
          fp_entry=$(printf '%s\n' "$line" | sed 's/^foundationProposalPath[[:space:]]*:[[:space:]]*//')
          fp_entry=$(printf '%s\n' "$fp_entry" | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//')
          case "$fp_entry" in
            \"*\") fp_entry="${fp_entry#\"}"; fp_entry="${fp_entry%\"}" ;;
            \'*\') fp_entry="${fp_entry#\'}"; fp_entry="${fp_entry%\'}" ;;
          esac
          fp_entry="${fp_entry#./}"
          referenced_set="$referenced_set
$fp_entry"
          continue
        fi
        if [ "$in_rp" -eq 1 ]; then
          # List item: lines starting with optional spaces then - followed by space
          if printf '%s\n' "$line" | grep -qE '^\s*-\s+'; then
            local rp_entry
            rp_entry=$(printf '%s\n' "$line" | sed 's/^\s*-\s\+//')
            rp_entry="${rp_entry#./}"
            referenced_set="$referenced_set
$rp_entry"
          elif printf '%s\n' "$line" | grep -qE '^\s*[a-zA-Z]'; then
            # A new key — exit researchPaths block
            in_rp=0
          fi
        fi
      done < "$bfile"
    done
  fi

  # Compute threshold: now - 30 days in seconds
  local now threshold
  now=$(date +%s)
  threshold=$((now - 30 * 86400))

  local cleaned=0

  # Iterate .aimi/research/*.md
  for rfile in "$research_dir"/*.md; do
    [ -f "$rfile" ] || continue

    # Compute relative path from PROJECT_ROOT (for set membership check)
    local rel_path
    if [ "${rfile#/}" = "$rfile" ]; then
      # Relative path already — but canonicalize via PROJECT_ROOT
      rel_path="$AIMI_DIR/research/$(basename "$rfile")"
    else
      # Absolute — make relative to PROJECT_ROOT
      rel_path="${rfile#"$PROJECT_ROOT/"}"
    fi
    rel_path="${rel_path#./}"

    # Check if this file is in the referenced-set
    local is_referenced=0
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      ref_norm="${ref#./}"
      if [ "$ref_norm" = "$rel_path" ]; then
        is_referenced=1
        break
      fi
    done <<< "$referenced_set"

    if [ "$is_referenced" -eq 1 ]; then
      continue
    fi

    # Check mtime: only delete if older than threshold
    local file_mtime
    file_mtime=$(stat -c '%Y' "$rfile" 2>/dev/null || stat -f '%m' "$rfile" 2>/dev/null)
    if [ -z "$file_mtime" ]; then
      continue
    fi

    if [ "$file_mtime" -lt "$threshold" ]; then
      rm -f "$rfile"
      cleaned=$((cleaned + 1))
    fi
  done

  if [ "$cleaned" -gt 0 ]; then
    echo "Cleaned $cleaned orphaned research files (>30 days)"
  fi
}

# ============================================================================
# story-merge: Consolidate staging files into a validated tasks.json
# Usage: aimi-cli.sh story-merge --staging-dir <dir> --output <path>
#           [--split legacy|full-stack] [--agent-mode] [--phase-aware]
#           [--foundation <NN>]
# ============================================================================

# _story_merge_assign_ids: given a JSON array of story objects (already loaded),
# assign sequential US-NNN IDs by lexicographic order of their source filename.
# The $1 array has objects with a synthetic "srcFile" key attached before this call.
# Returns the array with id fields populated.

cmd_story_merge() {
  local staging_dir="" output_path="" split_mode="legacy" agent_mode=false phase_aware=false foundation_idx=""
  # Resolved by the --foundation injection sweep below and consumed (only) by
  # the PROJECT-axis writer, which flags cross-group edges onto it distinctly.
  # Stays "" whenever --foundation was omitted, so no real id can match it.
  local foundation_id=""

  # --- Parse flags ---
  while [ $# -gt 0 ]; do
    case "$1" in
      --staging-dir)
        shift
        staging_dir="${1:-}"
        ;;
      --output)
        shift
        output_path="${1:-}"
        ;;
      --split)
        shift
        split_mode="${1:-legacy}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      --phase-aware)
        phase_aware=true
        ;;
      --foundation)
        shift
        foundation_idx="${1:-}"
        ;;
      *)
        echo "Error: story-merge: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  # --- Validate required flags ---
  if [ -z "$staging_dir" ]; then
    echo "Error: story-merge: --staging-dir <path> is required" >&2
    exit 1
  fi
  if [ -z "$output_path" ]; then
    echo "Error: story-merge: --output <path> is required" >&2
    exit 1
  fi
  if [ "$split_mode" != "legacy" ] && [ "$split_mode" != "full-stack" ]; then
    echo "Error: story-merge: --split must be 'legacy' or 'full-stack', got: $split_mode" >&2
    exit 1
  fi
  if [ -n "$foundation_idx" ] && ! [[ "$foundation_idx" =~ ^[0-9]{2}$ ]]; then
    echo "Error: story-merge: --foundation must be a two-digit index (e.g. 01), got: $foundation_idx" >&2
    exit 1
  fi
  # --phase-aware strips ONE trailing "-tasks" segment from the --output
  # basename. Both writers do that strip with the same `${base_no_ext%-tasks}`
  # expansion, and on a basename that is exactly "tasks" the strip is a no-op
  # while on "-tasks" it collapses to the empty string -- either way the
  # derived name degenerates (".../-frontend-tasks.json", ".../-<slug>-tasks.json":
  # a basename starting with "-", which every downstream tool reads as a flag).
  # Guarding inside the writers would mean either fixing one axis and leaving
  # the other, or changing SIDE-axis behavior; refusing the input here leaves
  # both strips byte-identical and costs the caller one well-named error.
  # The derivation below mirrors the writers' exactly (basename, strip the
  # extension after the LAST dot) so the precondition can never drift from the
  # expansion it protects.
  if [ "$phase_aware" = true ]; then
    local pa_base pa_ext pa_no_ext
    pa_base=$(basename "$output_path")
    pa_ext="${pa_base##*.}"
    pa_no_ext="${pa_base%.$pa_ext}"
    case "$pa_no_ext" in
      # ?* before "-tasks": at least one character must survive the strip.
      ?*-tasks) ;;
      *)
        echo "Error: story-merge: --phase-aware requires an --output basename ending in \"-tasks\"" >&2
        echo "(phase-scoped form, e.g. <feature>-phase-<N>-tasks.json); got: $pa_base" >&2
        exit 1
        ;;
    esac
  fi

  # --- Validate paths are inside project ---
  validate_path_in_project "$staging_dir"
  local output_parent
  output_parent=$(dirname "$output_path")
  # output_path may not exist yet; validate parent dir or the path itself
  if [ -e "$output_path" ]; then
    validate_path_in_project "$output_path"
  elif [ -e "$output_parent" ]; then
    validate_path_in_project "$output_parent"
  fi

  # --- Staging dir must exist ---
  if [ ! -d "$staging_dir" ]; then
    echo "Error: story-merge: staging directory does not exist: $staging_dir" >&2
    exit 1
  fi

  # --- Glob *.json files, sorted lexicographically ---
  # Skip non-story sidecars written by plan.md Phase 3b (outline.json) and any
  # future *outline*.json metadata files — they have a different shape and would
  # be mis-merged as bogus stories.
  local staging_files=()
  while IFS= read -r f; do
    local fbase
    fbase=$(basename "$f")
    case "$fbase" in
      outline.json|*outline*.json|metadata.json|audit-result.json) continue ;;
    esac
    staging_files+=("$f")
  done < <(find "$staging_dir" -maxdepth 1 -name '*.json' -type f | sort)

  if [ ${#staging_files[@]} -eq 0 ]; then
    echo "Error: story-merge: no *.json files found in $staging_dir" >&2
    exit 1
  fi

  # --- Validate each file is valid JSON and extract numeric index prefix ---
  # Also detect duplicate numeric index prefixes
  local -A seen_indices
  local files_ordered=()
  for f in "${staging_files[@]}"; do
    local base
    base=$(basename "$f")
    # Validate JSON
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "Error: story-merge: malformed JSON in file: $base" >&2
      exit 1
    fi
    # Extract numeric prefix (leading digits up to first non-digit)
    local idx
    idx=$(printf '%s' "$base" | sed 's/^\([0-9]*\).*/\1/')
    if [ -n "$idx" ]; then
      if [ -n "${seen_indices[$idx]+_}" ]; then
        echo "Error: story-merge: duplicate index '$idx' in files: ${seen_indices[$idx]} and $base" >&2
        exit 1
      fi
      seen_indices[$idx]="$base"
    fi
    files_ordered+=("$f")
  done

  # --- Load all staging story objects, attaching a _srcIdx field (0-based) ---
  # Build a single merged JSON array from all files.
  # Each staging file should be either a single story object or an array of stories.
  local merged_array="[]"
  local story_idx=0
  for f in "${files_ordered[@]}"; do
    local content
    content=$(cat "$f")
    # Detect if top-level is array or object
    local kind
    kind=$(printf '%s' "$content" | jq -r 'if type == "array" then "array" else "object" end')
    if [ "$kind" = "array" ]; then
      # Flatten array entries, attaching _srcIdx to each
      local base
      base=$(basename "$f")
      merged_array=$(printf '%s\n%s' "$merged_array" "$content" | jq -s \
        --arg base "$base" \
        '.[0] as $acc | .[1] as $arr |
         $acc + ($arr | map(. + {_srcIdx: ('$story_idx' + (. | path) | if . == null then 0 else . end)}))
        ' 2>/dev/null) || true
      # Simpler approach: just append with sequential indices
      local arr_len
      arr_len=$(printf '%s' "$content" | jq 'length')
      local i
      for (( i=0; i<arr_len; i++ )); do
        local story_obj
        story_obj=$(printf '%s' "$content" | jq ".[$i]")
        merged_array=$(printf '%s' "$merged_array" | jq \
          --argjson s "$story_obj" \
          --argjson idx "$story_idx" \
          '. + [$s + {_srcIdx: $idx}]')
        story_idx=$((story_idx + 1))
      done
      merged_array=$(printf '%s' "$merged_array" | jq '.')
    else
      # Single story object
      merged_array=$(printf '%s' "$merged_array" | jq \
        --argjson s "$content" \
        --argjson idx "$story_idx" \
        '. + [$s + {_srcIdx: $idx}]')
      story_idx=$((story_idx + 1))
    fi
  done

  local total_stories
  total_stories=$(printf '%s' "$merged_array" | jq 'length')

  # --- Assign US-NNN IDs by source index (lex order of files, order within file) ---
  merged_array=$(printf '%s' "$merged_array" | jq '
    to_entries | map(
      .value + {id: ("US-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}
    )
  ')

  # Also build index→id map (srcIdx → US-NNN) for outline:NN remap
  local idx_to_id
  idx_to_id=$(printf '%s' "$merged_array" | jq '[
    .[] | {key: (.._srcIdx | tostring), value: .id} | select(.key != null)
  ] | from_entries' 2>/dev/null || echo '{}')
  # Simpler: build map as array of [srcIdx, id]
  idx_to_id=$(printf '%s' "$merged_array" | jq '[.[] | {srcIdx: ._srcIdx, id: .id}]')

  # --- Remap outline:NN tokens in dependsOn arrays ---
  # "outline:02" → US-NNN where srcIdx == 2 (zero-padded 2 = index 1? no: outline index is 1-based per decision)
  # Decision: "Sub-agents emit dependsOn entries as 'outline:NN' (zero-padded, matching the outline order)"
  # The outline order matches file lex order → outline:01 = first story (srcIdx=0) → US-001
  # So outline:NN (1-based) → srcIdx = NN - 1 → look up US-NNN
  merged_array=$(printf '%s\n%s' "$merged_array" "$idx_to_id" | jq -s '
    .[0] as $stories |
    .[1] as $idx_map |

    # Build outline-index → US-NNN map: outline:01 means 1-based index = srcIdx 0
    ($stories | to_entries | map({key: (.key + 1 | tostring | if length == 1 then "0" + . else . end), value: .value.id}) | from_entries) as $outline_map |

    $stories | map(
      .dependsOn = [
        (.dependsOn // [])[] |
        if startswith("outline:") then
          (ltrimstr("outline:")) as $nn |
          if $outline_map[$nn] != null then $outline_map[$nn]
          else "UNRESOLVED_OUTLINE:" + $nn
          end
        else
          .
        end
      ]
    )
  ')

  # Check for unresolved outline refs
  local unresolved
  unresolved=$(printf '%s' "$merged_array" | jq -r '
    [.[] | .id as $sid | (.dependsOn // [])[] | select(startswith("UNRESOLVED_OUTLINE:")) | $sid + ": " + .] | .[]
  ')
  if [ -n "$unresolved" ]; then
    echo "Error: story-merge: unresolved outline reference(s):" >&2
    printf '%s\n' "$unresolved" >&2
    exit 1
  fi

  # --- Remove synthetic _srcIdx field before further processing ---
  merged_array=$(printf '%s' "$merged_array" | jq '[.[] | del(._srcIdx)]')

  # --- Resolve the split axis (and refuse unrouteable .project values) ---
  # Earliest point at which every story carries its final US-NNN id, and still
  # ahead of --foundation, cycle detection, and the Phase 3.1/4.1/4.2 sweeps:
  # a refusal here costs nothing and cannot emit a warning about a plan that
  # was never going to be written. The axis is decided ONCE, here, and the
  # writers below only read the answer.
  local split_axis
  split_axis=$(_story_merge_resolve_axis "$merged_array" "$split_mode") || exit 1

  # --- Foundation dependsOn injection sweep (--foundation NN) ---
  # Runs after the outline:NN remap and _srcIdx strip, and before both the
  # Kahn's-algorithm cycle detection and wave computation below, so injected
  # edges are naturally included in both without touching either block.
  # foundation_idx is an outline position (1-based, same convention as
  # outline:NN tokens) — resolved against the array's own position, not
  # against a literal staging-filename digit.
  # Cycle-safe by construction: the foundation's own dependsOn is asserted
  # empty before any edge is added, and injection only ever adds edges
  # pointing toward the foundation (never away from it), so no new cycle can
  # be introduced; the Kahn's-algorithm check below still runs unmodified.
  if [ -n "$foundation_idx" ]; then
    foundation_id=$(printf '%s' "$merged_array" | jq -r --arg nn "$foundation_idx" '
      (to_entries | map({key: (.key + 1 | tostring | if length == 1 then "0" + . else . end), value: .value.id}) | from_entries) as $outline_map |
      $outline_map[$nn] // ""
    ')
    if [ -z "$foundation_id" ]; then
      echo "Error: story-merge: --foundation $foundation_idx not present among staging files" >&2
      exit 1
    fi

    local foundation_depends_on
    foundation_depends_on=$(printf '%s' "$merged_array" | jq -c --arg fid "$foundation_id" '[.[] | select(.id == $fid)][0].dependsOn // []')
    if [ "$foundation_depends_on" != "[]" ]; then
      echo "Error: story-merge: foundation story $foundation_id has non-empty dependsOn" >&2
      exit 1
    fi

    merged_array=$(printf '%s' "$merged_array" | jq --arg fid "$foundation_id" '
      map(
        if .id == $fid then
          .
        else
          .dependsOn = (
            (.dependsOn // []) as $d |
            if ($d | index($fid)) != null then $d else $d + [$fid] end
          )
        end
      )
    ')
  fi

  # --- DAG cycle detection via topological sort (Kahn's algorithm in jq) ---
  local cycle_result
  cycle_result=$(printf '%s' "$merged_array" | jq '
    . as $stories |
    ($stories | map(.id)) as $all_ids |

    # Build adjacency: dependsOn edges (dep → story means story depends on dep)
    # For cycle detection, we want to find if any node is reachable from itself
    # via Kahn topological sort: if remaining nodes exist after sort, there is a cycle

    # Compute in-degree for each node
    (reduce $stories[] as $s (
      {};
      . + {($s.id): (($s.dependsOn // []) | length)}
    )) as $in_degree |

    # Compute adjacency list: adj[dep_id] = [story_ids that depend on dep_id]
    (reduce $stories[] as $s (
      {};
      reduce ($s.dependsOn // [])[] as $dep (
        .;
        .[$dep] = (.[$dep] // []) + [$s.id]
      )
    )) as $adj |

    # Kahn: start with zero in-degree nodes
    ([$stories[] | select((($in_degree[.id]) // 0) == 0) | .id]) as $initial_queue |

    # Iterate using fixed accumulator variable binding
    (reduce range($stories | length) as $_ (
      {queue: $initial_queue, deg: $in_degree, visited: []};
      if (.queue | length) == 0 then .
      else
        .queue[0] as $node |
        .deg as $cur_deg |
        .visited as $cur_vis |
        .queue[1:] as $rest_q |
        ($adj[$node] // []) as $neighbors |
        (reduce $neighbors[] as $n ($cur_deg; .[$n] = ((.[$n] // 1) - 1))) as $new_deg |
        {
          queue: ($rest_q + [$neighbors[] | . as $n | select(($new_deg[$n] // 0) == 0)]),
          deg: $new_deg,
          visited: ($cur_vis + [$node])
        }
      end
    )) as $result |

    if ($result.visited | length) == ($stories | length) then
      {cycle: false, stories_in_cycle: []}
    else
      {
        cycle: true,
        stories_in_cycle: [$stories[] | .id | select(. as $id | ($result.visited | index($id)) == null)]
      }
    end
  ')

  local has_cycle
  has_cycle=$(printf '%s' "$cycle_result" | jq -r '.cycle')
  if [ "$has_cycle" = "true" ]; then
    local cycle_stories
    cycle_stories=$(printf '%s' "$cycle_result" | jq -r '.stories_in_cycle | join(", ")')
    echo "Error: story-merge: circular dependency detected among stories: $cycle_stories" >&2
    exit 1
  fi

  # --- Wave computation: roots = wave 1, others = max(dep waves) + 1 ---
  merged_array=$(printf '%s' "$merged_array" | jq '
    . as $stories |
    # Iterative wave assignment: repeat until stable (max N iterations)
    reduce range($stories | length) as $_ (
      ($stories | map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)}));
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')

  # --- Rule 22: Mock-sync AC routing ---
  # Process each schema-extending story: route mock-sync ACs to consumer stories.
  # We implement this as a shell loop to avoid complex nested jq.
  local schema_ids
  schema_ids=$(printf '%s' "$merged_array" | jq -r '
    .[] | select(
      (.implementation.files // []) | any(
        test("schemas/.*\\.(ts|js|py|rb)$") or
        test("types/.*\\.(ts|js)$") or
        test("zod/.*\\.(ts|js)$") or
        test("\\.schema\\.ts$") or
        test("\\.types\\.ts$")
      )
    ) | .id
  ')

  local schema_id
  for schema_id in $schema_ids; do
    # Check if schema story has a mock-sync AC
    local has_mock
    has_mock=$(printf '%s' "$merged_array" | jq -r \
      --arg sid "$schema_id" \
      '.[] | select(.id == $sid) | .acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; ""))) | length > 0')
    [ "$has_mock" = "true" ] || continue

    # Extract schema story text for field-name extraction
    local schema_text
    schema_text=$(printf '%s' "$merged_array" | jq -r \
      --arg sid "$schema_id" \
      '.[] | select(.id == $sid) | [.title, (.description // "")] + (.acceptanceCriteria // []) | join(" ")')

    # Step 1: Extract camelCase field names (lowercase-starting)
    local field_names
    field_names=$(printf '%s' "$schema_text" | jq -rR \
      '[scan("[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*|[a-z][a-z0-9_]*_[a-z][a-z0-9_]*")] | map(select(length > 3)) | .[]' 2>/dev/null || true)

    # Step 2: Find consumers via field-name literal match
    local consumer_ids=""
    if [ -n "$field_names" ]; then
      consumer_ids=$(printf '%s' "$merged_array" | jq -r \
        --arg sid "$schema_id" \
        --arg fields "$field_names" \
        '
        ($fields | split("\n") | map(select(length > 0))) as $fn_list |
        .[] | select(.id != $sid) |
        . as $c |
        ([$c.title, ($c.description // "")] + ($c.acceptanceCriteria // []) | join(" ")) as $ctext |
        select($fn_list | any(. as $fn | ($ctext | test($fn; "")))) |
        .id
        ' 2>/dev/null || true)
    fi

    # Step 3: CamelCase entity-name fuzzy fallback
    if [ -z "$consumer_ids" ]; then
      local schema_title
      schema_title=$(printf '%s' "$merged_array" | jq -r --arg sid "$schema_id" '.[] | select(.id == $sid) | .title')
      local word_parts
      word_parts=$(printf '%s' "$schema_title" | jq -rR '[scan("[A-Z][a-z]+")] | .[]' 2>/dev/null || true)
      if [ -n "$word_parts" ]; then
        consumer_ids=$(printf '%s' "$merged_array" | jq -r \
          --arg sid "$schema_id" \
          --arg words "$word_parts" \
          '
          ($words | split("\n") | map(select(length > 0))) as $wp_list |
          .[] | select(.id != $sid) |
          . as $c |
          ([$c.title, ($c.description // "")] + ($c.acceptanceCriteria // []) | join(" ")) as $ctext |
          select($wp_list | any(. as $wp | ($ctext | test($wp; "i")))) |
          .id
          ' 2>/dev/null || true)
      fi
    fi

    [ -n "$consumer_ids" ] || continue

    # Route: move mock-sync AC from schema story to each consumer
    merged_array=$(printf '%s' "$merged_array" | jq \
      --arg sid "$schema_id" \
      --arg consumer_list "$consumer_ids" \
      '
      ($consumer_list | split("\n") | map(select(length > 0))) as $cids |

      # Extract mock-sync ACs from schema story
      ((.[] | select(.id == $sid)).acceptanceCriteria // [] |
        map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; "")))) as $mock_acs |

      map(
        . as $s |
        if $s.id == $sid then
          $s + {acceptanceCriteria: ($s.acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; "") | not)))}
        elif ($cids | index($s.id)) != null then
          ($s.acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; ""))) | length == 0) as $no_mock |
          if $no_mock then
            $s + {acceptanceCriteria: (($s.acceptanceCriteria // []) + $mock_acs)}
          else $s
          end
        else $s
        end
      )
      ')
  done

  # --- Phase 3.1: Reference Element Inventory verdict check ---
  # Check for any story that has an inventory with unverdicted rows
  local inventory_errors=""
  local inventory_warnings=""
  local inv_check
  inv_check=$(printf '%s' "$merged_array" | jq '
    [.[] |
      . as $s |
      select(
        (.referenceInventory != null) and
        (.referenceInventory | type) == "array" and
        (.referenceInventory | length) > 0
      ) |
      . as $s |
      [.referenceInventory[] | select(
        (.verdict == null or .verdict == "" or (.verdict | test("^(encoded|excluded|deferred)$") | not))
      )] as $unverdicted |
      select(($unverdicted | length) > 0) |
      {id: $s.id, unverdicted_count: ($unverdicted | length), elements: ($unverdicted | map(.element // "unknown"))}
    ]
  ')
  local inv_violations
  inv_violations=$(printf '%s' "$inv_check" | jq 'length')
  if [ "$inv_violations" -gt 0 ]; then
    local inv_msg
    inv_msg=$(printf '%s' "$inv_check" | jq -r '.[] | "  Story \(.id): \(.unverdicted_count) unverdicted inventory row(s): \(.elements | join(", "))"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 3.1 inventory verdict incomplete (--agent-mode: proceeding):" >&2
      printf '%s\n' "$inv_msg" >&2
    else
      echo "Error: story-merge: Phase 3.1 Reference Element Inventory has unverdicted rows:" >&2
      printf '%s\n' "$inv_msg" >&2
      exit 1
    fi
  fi

  # --- Phase 4.1: Coverage Self-Check ---
  # For each story with a referenceInventory, check ac_anchors >= floor(proto_elements * 0.6)
  local coverage_check
  coverage_check=$(printf '%s' "$merged_array" | jq '
    [.[] |
      select(
        (.referenceInventory != null) and
        (.referenceInventory | type) == "array" and
        (.referenceInventory | length) > 0
      ) |
      . as $s |
      (.referenceInventory | length) as $proto_elements |
      ($s.ac_anchors // (.acceptanceCriteria // [] | length)) as $ac_anchors |
      ($proto_elements * 0.6 | floor) as $threshold |
      select($ac_anchors < $threshold) |
      {id: $s.id, ac_anchors: $ac_anchors, proto_elements: $proto_elements, threshold: $threshold}
    ]
  ')
  local coverage_violations
  coverage_violations=$(printf '%s' "$coverage_check" | jq 'length')
  if [ "$coverage_violations" -gt 0 ]; then
    local cov_msg
    cov_msg=$(printf '%s' "$coverage_check" | jq -r '.[] | "  Story \(.id): ac_anchors=\(.ac_anchors) < floor(\(.proto_elements) * 0.6)=\(.threshold)"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 4.1 coverage ratio not met (--agent-mode: proceeding):" >&2
      printf '%s\n' "$cov_msg" >&2
    else
      echo "Error: story-merge: Phase 4.1 Coverage Self-Check failed:" >&2
      printf '%s\n' "$cov_msg" >&2
      exit 1
    fi
  fi

  # --- Phase 4.2: Cross-Story Orphan-Symbol Smell ---
  # Heuristic, WARNING-ONLY (never a hard block). NOT codebase dead-code
  # detection: it scans only sibling STORY PROSE, not the codebase. It flags a
  # story whose every extracted symbol (camelCase / PascalCase / snake_case,
  # length >= 4) from implementation.approach appears in NO other story's text
  # corpus (title + description + ACs + approach + files). Signal: a symbol the
  # plan introduces that no sibling story mentions may be an orphan addition.
  #
  # Known limits (text vs. semantics; sibling-prose vs. call graph):
  #   - Cannot prove a symbol is dead — that depends on existing callers in the
  #     actual codebase, which this check does not inspect.
  #   - False positives: legitimate leaf symbols (CLI entry points, webhook /
  #     cron handlers) have no sibling-story mention by design.
  #   - False negatives: a referencing story using a different name (alias,
  #     import rename, dynamic dispatch) is invisible to a text scan.
  # Skipped for single-story merges (no sibling corpus → every symbol would be
  # trivially flagged). Mirrors Phase 4.1's agent-mode warn-vs-emit convention.
  local _sm_story_count orphan_sym_check
  _sm_story_count=$(printf '%s' "$merged_array" | jq 'length')
  if [ "${_sm_story_count:-0}" -lt 2 ]; then
    orphan_sym_check='[]'
  else
    orphan_sym_check=$(printf '%s' "$merged_array" | jq '
      . as $all |
      [.[] |
        . as $s |
        select(
          (.implementation.approach != null) and
          ((.implementation.approach | type) == "string") and
          ((.implementation.approach | length) > 0)
        ) |
        (.implementation.approach) as $approach |
        # camelCase / PascalCase / snake_case identifiers, length >= 4;
        # single-case plain words are excluded to reduce noise.
        ($approach | [scan("[A-Za-z][A-Za-z0-9_]*")] |
          map(select(
            length >= 4 and
            (
              test("^[a-z].*[A-Z]") or
              test("^[A-Z][a-z]+[A-Z]") or
              test("_[a-z]")
            )
          ))
        ) as $symbols |
        select(($symbols | length) > 0) |
        ([$all[] |
            select(.id != $s.id) |
            [
              (.title // ""),
              (.description // ""),
              ((.acceptanceCriteria // []) | join(" ")),
              (.implementation.approach // ""),
              ((.implementation.files // []) | join(" "))
            ] | join(" ")
          ] | join(" ")
        ) as $other_corpus |
        # Word-boundary match: `userId` is NOT treated as referenced by an
        # unrelated `userIdentifier`. Symbols are [A-Za-z0-9_]+, so no regex
        # metacharacter can reach test().
        ($symbols | map(select(. as $sym | ($other_corpus | test("\\b" + $sym + "\\b")) | not))) as $unreferenced |
        select(($unreferenced | length) == ($symbols | length)) |
        {id: $s.id, symbols: $symbols}
      ]
    ')
  fi
  local orphan_sym_violations
  orphan_sym_violations=$(printf '%s' "$orphan_sym_check" | jq 'length')
  if [ "$orphan_sym_violations" -gt 0 ]; then
    local orphan_msg
    orphan_msg=$(printf '%s' "$orphan_sym_check" | jq -r \
      '.[] | "  Story \(.id): introduces symbols no other story references: \(.symbols | join(", "))"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (--agent-mode: proceeding):" >&2
      printf '%s\n' "$orphan_msg" >&2
    else
      echo "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (heuristic; verify before proceeding):" >&2
      printf '%s\n' "$orphan_msg" >&2
    fi
  fi

  # ============================================================
  # Phase 4.2 → smellWarnings metadata field
  # ============================================================
  # Surface orphan-symbol findings to the orchestrator's Step 5 report by
  # embedding them in metadata.smellWarnings. The writers below inject this
  # field only when non-empty; absent otherwise.
  local smell_warnings
  if [ "${orphan_sym_violations:-0}" -gt 0 ]; then
    smell_warnings=$(printf '%s' "$orphan_sym_check" | jq '[.[] | {type: "orphan-symbol", storyId: .id, symbols: .symbols, message: "introduces symbols no sibling story references"}]')
  else
    smell_warnings='[]'
  fi

  # ============================================================
  # Branch on split mode
  # ============================================================
  # The split AXIS was decided by _story_merge_resolve_axis immediately after
  # id assignment, before any of the sweeps above ran. Nothing is recomputed
  # here -- this block only dispatches on the answer, so there is no second
  # partition rule that could disagree with the one the writer groups by.
  if [ "$split_mode" = "full-stack" ]; then
    if [ "$split_axis" = "project" ]; then
      # foundation_id is threaded into the PROJECT writer ONLY. --foundation
      # injects one edge onto the foundation story from every other story; in
      # a multi-repo split every group that does not host the foundation loses
      # that edge and would otherwise look like an ordinary hand-authored
      # missing dependency. The SIDE writer keeps its byte-identical signature.
      _story_merge_write_project_split "$merged_array" "$output_path" "$staging_dir" "$smell_warnings" "$phase_aware" "$foundation_id"
    else
      _story_merge_write_split "$merged_array" "$output_path" "$staging_dir" "$smell_warnings" "$phase_aware"
    fi
  else
    _story_merge_write_legacy "$merged_array" "$output_path" "$staging_dir" "$smell_warnings"
  fi
}

# jq `def`s spliced into every program that needs a story's .project either
# classified or reduced to a stable grouping key. Shared by
# _story_merge_resolve_axis and _story_merge_write_project_split so the two can
# never drift apart -- an axis chosen from one rule and a group built from
# another is exactly how issue #72 came back (one branch, two repositories).
#
# Grouping/counting/classification ONLY -- neither the normalized nor the
# classified form is ever written back onto a story; .project must survive
# verbatim into the output files.
#
#   norm_project  -- trims surrounding whitespace, strips one trailing slash,
#                    and treats blank/whitespace-only (and absent) as null.
#   project_state -- validates the RAW value against the grammar execute.md
#                    publishes for .project, returning exactly one of
#                    "untagged" / "tagged" / "invalid". Deliberately inspects
#                    the raw string, not the trimmed one: " apps/web " is
#                    invalid rather than being quietly trimmed into a value
#                    whose raw form is what a downstream command would cd into.
#                    Only a fully blank string counts as untagged.
#   group_key     -- the single routing key. Both the axis decision and the
#                    grouping pass go through this and nothing else.
_STORY_MERGE_NORM_PROJECT_JQ='
def norm_project:
  if . == null then null
  else
    (. | gsub("^\\s+|\\s+$"; "")) as $t |
    if $t == "" then null
    elif ($t | endswith("/")) then $t[0:-1]
    else $t
    end
  end;

def project_state:
  if . == null then "untagged"
  elif (type != "string") then "invalid"
  elif ((. | gsub("^\\s+|\\s+$"; "")) == "") then "untagged"
  elif . == "." then "tagged"
  elif (test("^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*$")
        and ((split("/") | index("..")) == null)
        and ((test("//")) | not)) then "tagged"
  else "invalid"
  end;

def group_key: norm_project;
'

# Resolve the split AXIS from the merged array, refusing anything the axis
# cannot route unambiguously. Echoes exactly "project" or "side"; returns 1
# after printing a named refusal otherwise.
#
# Called once, early -- before --foundation, cycle detection, and the Phase
# 3.1/4.1/4.2 sweeps -- so a refusal costs nothing and emits no warnings about
# a plan that was never going to be written.
#
# Decision table (counts computed here, ONCE, and nowhere else):
#   any story with an invalid .project     -> refuse, in EVERY --split mode
#   distinct >= 1 AND untagged > 0         -> refuse (--split full-stack only)
#   distinct >= 2                          -> "project"  (multi-repo)
#   otherwise                              -> "side"     (single-repo/monorepo)
#
# The untagged rule tests distinct >= 1, not >= 2, deliberately: the failure
# this exists to stop is ONE tagged repo plus untagged stories, which counts as
# a single distinct project and would otherwise take the SIDE axis -- one file,
# one branch, two repositories.
#
# _rm_sanitize is applied HERE and only here. These lines print values that
# already failed validation and are therefore unbounded; on every success path
# .project is a routing key that must stay byte-identical between the key that
# groups and the key that is written.
_story_merge_resolve_axis() {
  local merged_array="$1"
  local split_mode="$2"

  # Malformed .project is refused in EVERY --split mode, legacy included: the
  # value is a repository path a downstream command will cd into, so
  # "../sibling-repo" must not reach a tasks file by any route.
  local invalid_stories
  invalid_stories=$(printf '%s' "$merged_array" | jq -r "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
    [.[] | . as $s | select(($s.project | project_state) == "invalid")] | .[] |
    "  " + .id + " (" + (.title | _rm_sanitize(200)) + "): invalid project " + (.project | tostring | _rm_sanitize(120))
  ')
  if [ -n "$invalid_stories" ]; then
    echo "Error: story-merge: story .project must match ^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*\$ with no \"..\" component, no \"//\", no surrounding whitespace, and no leading \"./\" (use \".\" for the root repository); no files were written:" >&2
    printf '%s\n' "$invalid_stories" >&2
    return 1
  fi

  if [ "$split_mode" != "full-stack" ]; then
    printf '%s' "side"
    return 0
  fi

  local axis_counts distinct_count untagged_count
  axis_counts=$(printf '%s' "$merged_array" | jq -c "$_STORY_MERGE_NORM_PROJECT_JQ"'
    [.[] | . as $s | {state: ($s.project | project_state), key: ($s.project | group_key)}] as $st |
    {
      distinct: ([$st[] | select(.state == "tagged") | .key] | unique | length),
      untagged: ([$st[] | select(.state == "untagged")] | length)
    }
  ')
  distinct_count=$(printf '%s' "$axis_counts" | jq -r '.distinct')
  untagged_count=$(printf '%s' "$axis_counts" | jq -r '.untagged')

  if [ "${distinct_count:-0}" -ge 1 ] && [ "${untagged_count:-0}" -gt 0 ]; then
    local untagged_stories
    untagged_stories=$(printf '%s' "$merged_array" | jq -r "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
      [.[] | . as $s | select(($s.project | project_state) == "untagged")] | .[] |
      "  " + .id + " (" + (.title | _rm_sanitize(200)) + "): no project"
    ')
    echo "Error: story-merge: --split full-stack: this plan tags $distinct_count project(s), so it is a multi-repo plan and EVERY story needs a project. A story that belongs to the root repository must say so explicitly with \".\" -- an absent project is not the root, it is unrouteable. No files were written; the staging dir was kept. Stories missing a project:" >&2
    printf '%s\n' "$untagged_stories" >&2
    return 1
  fi

  if [ "${distinct_count:-0}" -ge 2 ]; then
    printf '%s' "project"
  else
    printf '%s' "side"
  fi
  return 0
}

# Write a single merged tasks.json (legacy mode)
_story_merge_write_legacy() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"

  # Build the final tasks.json structure
  # Metadata is minimal; the caller (plan command) fills in the full metadata.
  # story-merge only provides structure; metadata.title, branchName, etc. come from
  # the staging context or are set to sensible defaults.
  # smellWarnings is injected only when non-empty so absent-by-default stays the norm.
  local tasks_json
  tasks_json=$(printf '%s\n%s' "$merged_array" "$smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks",
          type: "feat",
          branchName: "feat/merged",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | (.status //= "pending")]
    }
  ')

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_path")"

  # Atomic write via _lock
  local tmp_file
  tmp_file=$(mktemp "${output_path}.XXXXXX")
  (
    _lock "${output_path}.lock"
    printf '%s\n' "$tasks_json" > "$tmp_file"
    mv "$tmp_file" "$output_path"
  ) 200>"${output_path}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  if [ $exit_code -ne 0 ]; then
    echo "Error: story-merge: failed to write output file: $output_path" >&2
    exit 1
  fi

  # On success: delete the staging dir
  rm -rf "$staging_dir"

  local story_count
  story_count=$(printf '%s' "$merged_array" | jq 'length')
  jq -n \
    --arg output "$output_path" \
    --argjson stories "$story_count" \
    '{merged: $output, stories: $stories}'
}

# Write two split tasks files (full-stack mode, SIDE axis: frontend/backend).
# Chosen by cmd_story_merge for single-repo/monorepo layouts only -- fewer than
# 2 distinct normalized .project values across the merged array.
_story_merge_write_split() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"
  local phase_aware="${5:-false}"

  # Partition by the per-story frontend heuristic, unconditionally.
  #
  # This writer only ever sees a single-repo/monorepo merge: cmd_story_merge
  # routes every layout carrying >= 2 distinct normalized .project values to
  # _story_merge_write_project_split instead, so there is no project group to
  # vote on here and no project-aware branch. Every story is classified by its
  # own file-pattern/title verdict (implementation.files matching tsx/jsx/
  # components//pages//frontend//ui//client/, OR title+description matching the
  # UI/Frontend/Component/Page/View/React/Tailwind keyword set) -- byte-
  # identical to what the old monorepo-guard fallback produced, which covers
  # both "no story has .project" and "every story shares exactly one project".
  local tagged_stories
  tagged_stories=$(printf '%s' "$merged_array" | jq '
    def fe_heuristic:
      ((.implementation.files // []) | any(
        test("\\.(tsx|jsx)$") or test("components?/") or test("pages?/") or
        test("frontend/") or test("ui/") or test("client/")
      )) or
      ((.title + " " + (.description // "")) | test("\\b(UI|Frontend|Component|Page|View|React|Tailwind)\\b"; "i"));
    [.[] | . + {_fe: fe_heuristic}] | map(. + {_side: ._fe})
  ')

  # Bipartition: two select() passes over the single tagged-and-sided array,
  # so every story id structurally lands in exactly one output (never lost,
  # never duplicated) rather than incidentally so.
  local frontend_stories backend_stories
  frontend_stories=$(printf '%s' "$tagged_stories" | jq '[.[] | select(._side == true)]')
  backend_stories=$(printf '%s' "$tagged_stories" | jq '[.[] | select(._side == false)]')

  # Re-assign unique IDs: frontend US-001 ... US-N, backend US-(N+1) ... US-M
  local fe_count be_count
  fe_count=$(printf '%s' "$frontend_stories" | jq 'length')
  be_count=$(printf '%s' "$backend_stories" | jq 'length')

  # An empty split side still writes its (empty userStories) file below --
  # traced, does not crash downstream -- but is surfaced with a named warning
  # rather than failing silently.
  if [ "$fe_count" -eq 0 ]; then
    echo "Warning: story-merge: frontend split produced zero stories" >&2
  fi
  if [ "$be_count" -eq 0 ]; then
    echo "Warning: story-merge: backend split produced zero stories" >&2
  fi

  # Build ID remapping for frontend
  local fe_id_map="{}"
  fe_id_map=$(printf '%s' "$frontend_stories" | jq '
    to_entries | map({key: .value.id, value: ("US-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}) | from_entries
  ')

  # Build ID remapping for backend (offset by frontend count)
  local fe_count_n
  fe_count_n=$(printf '%s' "$frontend_stories" | jq 'length')
  local be_id_map="{}"
  be_id_map=$(printf '%s' "$backend_stories" | jq \
    --argjson offset "$fe_count_n" \
    'to_entries | map({key: .value.id, value: ("US-" + ((.key + $offset + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}) | from_entries')

  # Global pre-remap-id -> {newId, side, title} lookup map, built from BOTH
  # sides' stories + id maps BEFORE either dependsOn-remap block below runs.
  # A pre-remap id would exist in neither output file, so naming a dropped
  # cross-file target usefully requires resolving it against this map now.
  local global_id_map
  global_id_map=$(printf '%s\n%s\n%s\n%s' "$frontend_stories" "$fe_id_map" "$backend_stories" "$be_id_map" | jq -s '
    .[0] as $fe | .[1] as $fe_map | .[2] as $be | .[3] as $be_map |
    ([$fe[] | {key: .id, value: {newId: ($fe_map[.id] // .id), side: "frontend", title: .title}}]
     + [$be[] | {key: .id, value: {newId: ($be_map[.id] // .id), side: "backend", title: .title}}])
    | from_entries
  ')

  # Apply ID remap and rebuild dependsOn (remove cross-file refs) for frontend.
  # Alongside the existing remap, capture the pre-remap dep ids that did NOT
  # resolve against the LOCAL id_map (i.e. cross-file) as __droppedDeps, and
  # flag __becameRoot when the story had a non-empty dependsOn that is now
  # entirely gone as a direct result of the drop.
  frontend_stories=$(printf '%s\n%s' "$frontend_stories" "$fe_id_map" | jq -s '
    .[0] as $stories | .[1] as $id_map |
    $stories | map(
      . as $story |
      ($story.dependsOn // []) as $pre |
      ($pre | length > 0) as $had_deps |
      ([$pre[] | select(($id_map[.] // null) == null)]) as $dropped_ids |
      $story
      | .id = ($id_map[.id] // .id)
      | .dependsOn = [$pre[] | . as $dep | ($id_map[$dep] // null) | select(. != null)]
      | .__droppedDeps = $dropped_ids
      | .__becameRoot = ($had_deps and (.dependsOn == []))
    )
  ')

  # Apply ID remap and rebuild dependsOn for backend (same cross-file capture).
  backend_stories=$(printf '%s\n%s' "$backend_stories" "$be_id_map" | jq -s '
    .[0] as $stories | .[1] as $id_map |
    $stories | map(
      . as $story |
      ($story.dependsOn // []) as $pre |
      ($pre | length > 0) as $had_deps |
      ([$pre[] | select(($id_map[.] // null) == null)]) as $dropped_ids |
      $story
      | .id = ($id_map[.id] // .id)
      | .dependsOn = [$pre[] | . as $dep | ($id_map[$dep] // null) | select(. != null)]
      | .__droppedDeps = $dropped_ids
      | .__becameRoot = ($had_deps and (.dependsOn == []))
    )
  ')

  # ============================================================
  # Cross-file dependsOn: audible drop surfacing
  # ============================================================
  # Every dependsOn entry that failed local resolution above is, by
  # construction, resolvable in the OTHER side's global_id_map -- the
  # earlier outline:NN remap + unresolved-outline check (before this
  # function runs) guarantees every dependsOn entry reaching this point
  # names a real story somewhere in the merged array. Build one
  # smellWarnings entry per affected story (both sides combined), with
  # every title sanitized via _rm_sanitize before it enters JSON or stderr.
  local cross_file_warnings
  cross_file_warnings=$(printf '%s\n%s\n%s' "$frontend_stories" "$backend_stories" "$global_id_map" | jq -s "$_ROADMAP_SANITIZE_JQ"'
    .[0] as $fe | .[1] as $be | .[2] as $gmap |
    ( [$fe[] | . + {__side: "frontend"}] + [$be[] | . + {__side: "backend"}] ) as $all |
    [
      $all[] | select((.__droppedDeps // []) | length > 0) |
      . as $story |
      (
        [
          ($story.__droppedDeps // [])[] | . as $old |
          ($gmap[$old] // {newId: $old, side: "unknown", title: ""}) |
          {id: .newId, side: .side, title: (.title | _rm_sanitize(200))}
        ]
      ) as $dd |
      {
        type: "cross-file-dep-dropped",
        storyId: $story.id,
        side: $story.__side,
        becameRoot: $story.__becameRoot,
        droppedDeps: $dd,
        message: (
          ($dd | length | tostring) + " cross-file dependsOn edge(s) dropped targeting: " +
          ($dd | map(.title) | join("; ")) +
          (if $story.__becameRoot then " (story became a false wave-1 root)" else "" end)
        )
      }
    ]
  ')

  # Merge into the Phase 4.2 smell_warnings param BEFORE it is threaded into
  # either output file build below, so both files carry the same combined set.
  local combined_smell_warnings
  combined_smell_warnings=$(printf '%s\n%s' "$smell_warnings" "$cross_file_warnings" | jq -s '.[0] + .[1]')

  # Aggregated stderr banner (never per-edge -- legitimate FE<->API edges and
  # --foundation's one-injected-edge-per-story would otherwise flood every
  # normal full-stack plan). One summary line with total dropped-edge count
  # and distinct-affected-story count (both sides combined), followed by one
  # enumeration line per FALSE-ROOT story only.
  local total_dropped affected_count
  total_dropped=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps | length] | add // 0')
  affected_count=$(printf '%s' "$cross_file_warnings" | jq 'length')
  if [ "$affected_count" -gt 0 ]; then
    echo "Warning: story-merge: ${total_dropped} cross-file dependsOn edge(s) dropped across ${affected_count} affected stories (--split full-stack; see metadata.smellWarnings)" >&2
    local false_root_lines
    false_root_lines=$(printf '%s' "$cross_file_warnings" | jq -r '
      .[] | select(.becameRoot == true) |
      (.storyId + " (" + .side + "): became a false wave-1 root -- its cross-file dependsOn target(s) " +
       ([.droppedDeps[] | (.id + " (" + .side + ")")] | join(", ")) + " were dropped")
    ')
    if [ -n "$false_root_lines" ]; then
      printf '%s\n' "$false_root_lines" >&2
    fi
  fi

  # Recompute waves independently per file
  frontend_stories=$(printf '%s' "$frontend_stories" | jq '
    reduce range(length) as $_ (
      map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')
  backend_stories=$(printf '%s' "$backend_stories" | jq '
    reduce range(length) as $_ (
      map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')

  # Derive output paths
  local base_name ext fe_path be_path
  base_name=$(basename "$output_path")
  ext="${base_name##*.}"
  local base_no_ext="${base_name%.$ext}"
  # --phase-aware: the output basename for a phase-scoped invocation already
  # ends in "-tasks" (e.g. "<feature>-phase-<N>-tasks.json"). Strip that single
  # trailing "-tasks" segment once before appending "-frontend-tasks.json" /
  # "-backend-tasks.json" so the split basenames keep a single "tasks" segment
  # ("<feature>-phase-<N>-frontend-tasks.json") instead of doubling it. Default
  # (unflagged) derivation is untouched -- it keeps appending directly to the
  # full ".json"-stripped basename, preserving the existing double-"tasks"
  # legacy basename (e.g. "<slug>-tasks-frontend-tasks.json").
  if [ "$phase_aware" = true ]; then
    base_no_ext="${base_no_ext%-tasks}"
  fi
  local dir_part
  dir_part=$(dirname "$output_path")
  fe_path="${dir_part}/${base_no_ext}-frontend-tasks.json"
  be_path="${dir_part}/${base_no_ext}-backend-tasks.json"

  # Ensure output directory exists
  mkdir -p "$dir_part"

  # Build and write frontend tasks.json atomically
  # smellWarnings is injected only when non-empty; written to BOTH split files
  # (combined_smell_warnings = Phase 4.2 orphan-symbol + cross-file-dep-dropped)
  # so reviewers see the same full smell surface regardless of which file they
  # inspect first.
  local fe_json
  fe_json=$(printf '%s\n%s' "$frontend_stories" "$combined_smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks (frontend)",
          type: "feat",
          branchName: "feat/merged-frontend",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
    }
  ')
  local tmp_fe
  tmp_fe=$(mktemp "${fe_path}.XXXXXX")
  (
    _lock "${fe_path}.lock"
    printf '%s\n' "$fe_json" > "$tmp_fe"
    mv "$tmp_fe" "$fe_path"
  ) 200>"${fe_path}.lock"
  local fe_exit=$?
  rm -f "$tmp_fe" 2>/dev/null
  if [ $fe_exit -ne 0 ]; then
    echo "Error: story-merge: failed to write frontend output: $fe_path" >&2
    exit 1
  fi

  # Build and write backend tasks.json atomically
  local be_json
  be_json=$(printf '%s\n%s' "$backend_stories" "$combined_smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks (backend)",
          type: "feat",
          branchName: "feat/merged-backend",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
    }
  ')
  local tmp_be
  tmp_be=$(mktemp "${be_path}.XXXXXX")
  (
    _lock "${be_path}.lock"
    printf '%s\n' "$be_json" > "$tmp_be"
    mv "$tmp_be" "$be_path"
  ) 200>"${be_path}.lock"
  local be_exit=$?
  rm -f "$tmp_be" 2>/dev/null
  if [ $be_exit -ne 0 ]; then
    echo "Error: story-merge: failed to write backend output: $be_path" >&2
    exit 1
  fi

  # On success: delete the staging dir
  rm -rf "$staging_dir"

  local fe_count_out be_count_out
  fe_count_out=$(printf '%s' "$frontend_stories" | jq 'length')
  be_count_out=$(printf '%s' "$backend_stories" | jq 'length')
  jq -n \
    --arg fe "$fe_path" \
    --arg be "$be_path" \
    --argjson fe_count "$fe_count_out" \
    --argjson be_count "$be_count_out" \
    '{frontend: $fe, backend: $be, frontend_stories: $fe_count, backend_stories: $be_count}'
}

# Write N split tasks files (full-stack mode, PROJECT axis: one file per repo).
#
# Chosen by cmd_story_merge when the merged array carries >= 2 distinct
# normalized .project values -- a multi-repo layout. There is no
# frontend/backend side decision on this path at all: the split axis IS the
# project, so every repo named by a story gets its own valid, non-colliding
# tasks file instead of being force-fit into two side files.
#
# All-or-nothing contract: every output path, slug, and branchName is derived
# and validated BEFORE the first write, so a collision or an invalid branch
# name lands zero files. Once the write loop starts, a mid-loop failure names
# the files already on disk and keeps the staging dir so a retry is unambiguous.
_story_merge_write_project_split() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"
  local phase_aware="${5:-false}"
  # Pre-remap id of the --foundation story, or "" when the flag was omitted.
  # Compared against the PRE-remap dropped-dep ids below (the same namespace),
  # so an empty value can never match a real story.
  local foundation_id="${6:-}"

  # ============================================================
  # 1. Route every story to a project group
  # ============================================================
  # Group key = group_key, the same def _story_merge_resolve_axis chose the
  # axis with. There is no fallback for a null key and there must not be one:
  # this writer is only ever reached on the PROJECT axis, which the resolver
  # enters only when every story is tagged, so group_key is non-null by
  # construction. A `// "."` here would be a second normalization rule one
  # function away from the first -- exactly the divergence that produced one
  # file and one branch for two repositories (issue #72).
  # Groups are emitted in lexicographic order by normalized project path
  # (jq's `unique` sorts by codepoint), never staging-glob or first-encountered
  # order.
  local group_keys
  group_keys=$(printf '%s' "$merged_array" | jq -c "$_STORY_MERGE_NORM_PROJECT_JQ"'
    [.[] | . as $s | ($s.project | group_key)] | unique
  ')

  # ============================================================
  # 2. Per-group id assignment + cross-group dependsOn sweep
  # ============================================================
  # Ids are reassigned US-001..US-M in group order, each group taking a
  # contiguous block (mirrors the frontend-then-backend offset scheme of
  # _story_merge_write_split), so ids stay unique across the whole N-file set.
  # A dependsOn edge that crosses a group boundary cannot survive -- its target
  # lives in another file -- so it is dropped and captured as __droppedDeps,
  # with __becameRoot flagging a story whose entire dependsOn list vanished.
  #
  # Every select()/map() pass binds its story via `. as $s` first: piping a
  # story into map/has() rebinds `.` away from the story object, which has
  # already broken a prior fix to this function.
  local prepared
  prepared=$(printf '%s\n%s' "$merged_array" "$group_keys" | jq -s \
    --arg foundation_id "$foundation_id" \
    "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
    def pad3: tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end;
    def recompute_waves:
      reduce range(length) as $_ (
        map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
        . as $current |
        map(
          if .wave > 0 then .
          else
            . as $story |
            ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
            if ($dep_waves | all(. > 0)) then
              . + {wave: (($dep_waves | max) + 1)}
            else
              .
            end
          end
        )
      );
    .[0] as $stories | .[1] as $keys |
    # Stories bucketed per group, preserving merged (outline) order inside
    # each bucket.
    [ $keys[] | . as $g |
      {project: $g, stories: [$stories[] | . as $s | select(($s.project | group_key) == $g)]}
    ] as $buckets |
    # Running offset -> contiguous US-NNN block per group, in group order.
    (reduce range($buckets | length) as $i ({offset: 0, out: []};
      .offset as $off |
      ($buckets[$i].stories) as $bs |
      {
        offset: ($off + ($bs | length)),
        out: (.out + [{
          project: $buckets[$i].project,
          idmap: ([$bs | to_entries[] | . as $e | {key: $e.value.id, value: ("US-" + (($off + $e.key + 1) | pad3))}] | from_entries),
          stories: $bs
        }])
      }
    ) | .out) as $blocks |
    # Global pre-remap-id -> {newId, project, title} map, built across EVERY
    # group before any dependsOn remap runs, so a dropped cross-group target
    # can still be named usefully (it exists in no single output file).
    ([$blocks[] | . as $b | ($b.stories[] | . as $s |
       {key: $s.id, value: {newId: ($b.idmap[$s.id] // $s.id), project: $b.project, title: $s.title}})]
     | from_entries) as $gmap |
    [$blocks[] | . as $b |
      {
        project: $b.project,
        stories: ([$b.stories[] | . as $s |
          ($s.dependsOn // []) as $pre |
          (($pre | length) > 0) as $had_deps |
          ([$pre[] | . as $d | select(($b.idmap[$d] // null) == null)]) as $dropped_ids |
          $s
          | .id = ($b.idmap[$s.id] // $s.id)
          | .dependsOn = [$pre[] | . as $dep | ($b.idmap[$dep] // null) | select(. != null)]
          | .__droppedDeps = $dropped_ids
          | .__becameRoot = ($had_deps and (.dependsOn == []))
        ] | recompute_waves)
      }
    ] as $remapped |
    # One cross-group dependsOn smellWarnings entry per affected story, every
    # title sanitized before it enters JSON or stderr.
    #
    # This axis keys every entry by `project` -- the routing key of the group
    # that owns it -- at BOTH the top level and in every droppedDeps[]. There is
    # no frontend/backend verdict on this path, so there is no `side` field to
    # emit; `side` remains exclusive to _story_merge_write_split. The two keys
    # are mutually exclusive per axis, which is what lets the Step 5 renderer
    # pick whichever one an entry actually carries.
    #
    # foundationEdge marks a dropped edge that --foundation itself injected
    # into every non-foundation story. In a multi-repo split the foundation
    # lives in exactly one group, so every OTHER group loses that edge and
    # would otherwise be indistinguishable from a hand-authored missing
    # dependency. $foundation_id is the PRE-remap id (same namespace as
    # $old), and is "" when --foundation was omitted -- no real id matches it.
    [$remapped[] | . as $b | ($b.stories[] | . as $s |
      select(($s.__droppedDeps // []) | length > 0) |
      ([($s.__droppedDeps // [])[] | . as $old |
         ($gmap[$old] // {newId: $old, project: "unknown", title: ""}) |
         {id: .newId, project: .project, title: (.title | _rm_sanitize(200)),
          foundationEdge: (($foundation_id != "") and ($old == $foundation_id))}]) as $dd |
      ($dd | map(select(.foundationEdge == true)) | length) as $fcount |
      {
        type: "cross-file-dep-dropped",
        storyId: $s.id,
        project: $b.project,
        becameRoot: $s.__becameRoot,
        droppedDeps: $dd,
        message: (
          ($dd | length | tostring) + " cross-file dependsOn edge(s) dropped targeting: " +
          ($dd | map(.title) | join("; ")) +
          (if $fcount > 0 then
             " -- " + ($fcount | tostring) + " of these targets the shared --foundation story (" +
             ($dd | map(select(.foundationEdge == true))
                  | map(.id + " in project \"" + .project + "\"") | join(", ")) +
             "), an edge --foundation injected into every story rather than a hand-authored dependency"
           else "" end) +
          (if $s.__becameRoot then " (story became a false wave-1 root)" else "" end)
        )
      })
    ] as $cross_warnings |
    {blocks: $remapped, crossWarnings: $cross_warnings}
  ')

  # Merge into the Phase 4.2 smell_warnings param BEFORE any file is built, so
  # every one of the N files carries the same combined set.
  local cross_file_warnings combined_smell_warnings
  cross_file_warnings=$(printf '%s' "$prepared" | jq -c '.crossWarnings')
  combined_smell_warnings=$(printf '%s\n%s' "$smell_warnings" "$cross_file_warnings" | jq -s '.[0] + .[1]')

  # Aggregated stderr banner (never per-edge), mirroring the SIDE writer: one
  # summary line, then one enumeration line per FALSE-ROOT story only.
  local total_dropped affected_count
  total_dropped=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps | length] | add // 0')
  affected_count=$(printf '%s' "$cross_file_warnings" | jq 'length')
  if [ "$affected_count" -gt 0 ]; then
    echo "Warning: story-merge: ${total_dropped} cross-project dependsOn edge(s) dropped across ${affected_count} affected stories (--split full-stack, project axis; see metadata.smellWarnings)" >&2

    # --foundation note: separate from the drop-count banner above, because
    # these edges are structurally different -- the merge itself injected
    # them, so every non-foundation project group losing one is expected
    # fallout of combining --foundation with a multi-repo split, not a sign of
    # a hand-authored dependency that went missing.
    local foundation_edge_count foundation_story_count
    foundation_edge_count=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps[] | select(.foundationEdge == true)] | length')
    foundation_story_count=$(printf '%s' "$cross_file_warnings" | jq '[.[] | select((.droppedDeps // []) | any(.foundationEdge == true))] | length')
    if [ "${foundation_edge_count:-0}" -gt 0 ]; then
      echo "Note: story-merge: ${foundation_edge_count} of those edge(s), across ${foundation_story_count} stories, target the shared --foundation story, which lives in only one project group; --foundation injected them, so their loss is expected on a multi-repo split (see droppedDeps[].foundationEdge)" >&2
    fi

    local false_root_lines
    false_root_lines=$(printf '%s' "$cross_file_warnings" | jq -r '
      .[] | select(.becameRoot == true) |
      (.storyId + " (" + .project + "): became a false wave-1 root -- its cross-project dependsOn target(s) " +
       ([.droppedDeps[] | (.id + " (" + .project + ")")] | join(", ")) + " were dropped")
    ')
    if [ -n "$false_root_lines" ]; then
      printf '%s\n' "$false_root_lines" >&2
    fi
  fi

  # ============================================================
  # 3. Derive every output path / slug / branchName up front
  # ============================================================
  local base_name ext base_no_ext dir_part
  base_name=$(basename "$output_path")
  ext="${base_name##*.}"
  base_no_ext="${base_name%.$ext}"
  # --phase-aware: identical single-"tasks"-segment collapse the SIDE writer
  # applies. Pure string manipulation on the --output basename, independent of
  # the split axis, so it composes unchanged at any N.
  if [ "$phase_aware" = true ]; then
    base_no_ext="${base_no_ext%-tasks}"
  fi
  dir_part=$(dirname "$output_path")

  # slugify: a project path is NEVER interpolated raw into a filename. Every
  # character outside [A-Za-z0-9_-] (notably "/" and ".") becomes "-", runs
  # collapse, and leading/trailing "-" are trimmed; a value that flattens to
  # nothing (e.g. ".") becomes "root".
  local plan
  plan=$(printf '%s' "$prepared" | jq -c \
    --arg dir "$dir_part" \
    --arg base "$base_no_ext" '
    def slugify:
      (gsub("[^A-Za-z0-9_-]"; "-") | gsub("-+"; "-") | gsub("^-+|-+$"; "")) as $s |
      if $s == "" then "root" else $s end;
    .blocks | to_entries | map(
      . as $e | $e.value as $b | ($b.project | slugify) as $slug |
      {
        index: ($e.key + 1),
        # .project is carried through verbatim, never sanitized: it is the
        # routing key, and a lossy transform would make the key that groups
        # differ from the key that is written. Malformed values are refused
        # outright by _story_merge_resolve_axis, before this writer is reached.
        project: $b.project,
        slug: $slug,
        path: ($dir + "/" + $base + "-" + $slug + "-tasks.json"),
        branchName: ("feat/merged-" + $slug),
        storyCount: ($b.stories | length)
      }
    )
  ')

  # Basename collision: two distinct project values that flatten to the same
  # slug would silently overwrite each other. Hard-fail the WHOLE merge here,
  # before the first write, so zero output files land.
  local slug_collisions
  slug_collisions=$(printf '%s' "$plan" | jq -r '
    group_by(.slug) | map(select(length > 1)) | .[] |
    "  basename slug \"" + .[0].slug + "\" is shared by projects: " + (map(.project) | join(", "))
  ')
  if [ -n "$slug_collisions" ]; then
    echo "Error: story-merge: --split full-stack: distinct project values collide on the same output basename; no files were written:" >&2
    printf '%s\n' "$slug_collisions" >&2
    exit 1
  fi

  # Derived-name validation: every invariant the derived slug / path /
  # branchName must satisfy before a single file is opened. Abort the whole
  # merge on the first failure -- no partial write, no mangled fallback name.
  #
  # REFUSE, never truncate. Truncating two long project values to a common
  # prefix manufactures a slug collision, which the guard above would then
  # report as a basename conflict between projects that do not actually
  # conflict -- a wrong diagnosis for a limit the caller can fix directly.
  #
  # Legs, and why each limit is where it is:
  #   branchName regex  -- the invariant plan.md enforces before any git
  #                        operation. Currently unreachable given slugify's
  #                        output; kept because it costs one test() and is the
  #                        only thing standing between a future slugify edit
  #                        and a branch name handed to git unchecked.
  #   slug <= 64        -- plan.md rewrites branchName to a ~87-char prefix in
  #                        phase mode; 87 + 64 stays inside every downstream
  #                        limit.
  #   basename <= 248   -- NAME_MAX (255) minus the 7 bytes mktemp appends for
  #                        ".XXXXXX". This is the leg that actually prevents a
  #                        mid-loop mktemp death, and it has to be checked on
  #                        the basename rather than the slug because most of
  #                        that basename comes from --output, not from .project.
  #   path <= 4000      -- PATH_MAX (4096) with headroom for the lock/tmp
  #                        suffixes appended to it.
  #   branchName <= 100 -- worktree-manager places a worktree as a single
  #                        directory component, so branchName feeds a
  #                        NAME_MAX-bounded name downstream.
  local bad_derived
  bad_derived=$(printf '%s' "$plan" | jq -r --arg re "$_ROADMAP_BRANCH_REGEX" '
    .[] | . as $g |
    ($g.path | split("/") | last) as $base |
    [
      (if ($g.branchName | test($re)) then empty
       else "derived branchName failed validation against " + $re + ": " + $g.branchName end),
      (if ($g.slug | length) > 64 then
         "derived basename slug is " + (($g.slug | length) | tostring) + " chars (limit 64): " + $g.slug
       else empty end),
      (if ($base | length) > 248 then
         "derived output basename is " + (($base | length) | tostring) +
         " chars (limit 248 = NAME_MAX 255 minus the 7-char mktemp suffix): " + $base
       else empty end),
      (if ($g.path | length) > 4000 then
         "derived output path is " + (($g.path | length) | tostring) + " chars (limit 4000)"
       else empty end),
      (if ($g.branchName | length) > 100 then
         "derived branchName is " + (($g.branchName | length) | tostring) + " chars (limit 100): " + $g.branchName
       else empty end)
    ] | .[] | "  project \"" + $g.project + "\": " + .
  ')
  if [ -n "$bad_derived" ]; then
    echo "Error: story-merge: --split full-stack: derived output name(s) failed validation; no files were written (shorten the offending project value -- names are refused, never truncated, because truncation would manufacture a basename collision between two distinct projects):" >&2
    printf '%s\n' "$bad_derived" >&2
    exit 1
  fi

  # ============================================================
  # 4. Write every group's file atomically
  # ============================================================
  mkdir -p "$dir_part"

  local group_total
  group_total=$(printf '%s' "$plan" | jq 'length')

  local written_paths=""
  local idx=0
  while [ "$idx" -lt "$group_total" ]; do
    # tmp_group and write_exit are declared at their use site below, where the
    # initialization they need is part of the same statement.
    local group_path group_json
    group_path=$(printf '%s' "$plan" | jq -r --argjson i "$idx" '.[$i].path')

    # metadata.splitGroup is the self-describing marker for this file's place
    # in the N-way split: its own project, its 1-based index, the total, and
    # every sibling file's path. Downstream consumers discover the full set
    # from it instead of re-deriving it from filename string conventions.
    group_json=$(printf '%s\n%s\n%s' "$prepared" "$plan" "$combined_smell_warnings" | jq -s --argjson i "$idx" '
      .[0] as $prep | .[1] as $plan | .[2] as $smells |
      $plan[$i] as $g |
      $prep.blocks[$i] as $b |
      {
        schemaVersion: "3.3",
        metadata: (
          {
            title: ("feat: merged tasks (" + $g.slug + ")"),
            type: "feat",
            branchName: $g.branchName,
            createdAt: (now | strftime("%Y-%m-%d")),
            planPath: null,
            splitGroup: {
              project: $g.project,
              index: $g.index,
              total: ($plan | length),
              siblings: [$plan[] | . as $sib | select($sib.index != $g.index) | $sib.path]
            }
          } +
          (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
        ),
        userStories: [$b.stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
      }
    ')

    # This script runs `set -euo pipefail`. A bare failing compound command
    # exits the shell immediately, so a `write_exit=$?` on the NEXT line is
    # unreachable and the whole error branch below with it -- which is exactly
    # how a failed group write used to leave one file on disk advertising
    # `total: 3` with two siblings that do not exist, an orphaned mktemp file,
    # and no message at all.
    #
    # Three details keep this reachable, and all three are load-bearing:
    #   1. `write_exit=0` is a real initialization. `-u` is on, and a bare
    #      `local write_exit` leaves it declared-but-unset, which makes
    #      `[ "$write_exit" -ne 0 ]` an unbound-variable error rather than a
    #      false. It is also never `local write_exit=$?`: `local` is a builtin
    #      and its own exit status overwrites `$?` before the assignment reads it.
    #   2. The `|| write_exit=$?` makes the subshell the left side of an AND-OR
    #      list, the one construct `set -e` is defined to exempt. The `200>`
    #      redirect stays attached to the subshell, BEFORE the `||`, so a lock
    #      path that cannot be opened (e.g. a directory) is a failure of the
    #      exempted command rather than of the list.
    #   3. mktemp gets the same treatment. It fails on ENOSPC/EACCES, and a
    #      bare failing assignment is just as fatal under `set -e`.
    local tmp_group=""
    tmp_group=$(mktemp "${group_path}.XXXXXX" 2>/dev/null) || tmp_group=""
    local write_exit=0
    if [ -z "$tmp_group" ]; then
      write_exit=1
    else
      (
        _lock "${group_path}.lock"
        printf '%s\n' "$group_json" > "$tmp_group"
        mv "$tmp_group" "$group_path"
      ) 200>"${group_path}.lock" || write_exit=$?
      [ -n "$tmp_group" ] && rm -f "$tmp_group" 2>/dev/null || true
    fi
    if [ "$write_exit" -ne 0 ]; then
      # Enumerate all THREE sets. The surviving files are the actionable part:
      # each one advertises a splitGroup.total and a siblings[] list describing
      # a complete N-way split that does not exist on disk, so the reader needs
      # to know precisely which of those siblings landed and which never will.
      local not_attempted remaining
      remaining=$((group_total - idx - 1))
      echo "Error: story-merge: failed to write project split output: $group_path" >&2
      echo "  Written before this failure (${idx}):" >&2
      if [ -n "$written_paths" ]; then
        printf '%s\n' "$written_paths" >&2
      else
        echo "    (none)" >&2
      fi
      echo "  Failed:" >&2
      echo "    $group_path" >&2
      echo "  Not attempted (${remaining}):" >&2
      if [ "$remaining" -gt 0 ]; then
        not_attempted=$(printf '%s' "$plan" | jq -r --argjson i "$idx" '.[($i + 1):][] | "    " + .path')
        printf '%s\n' "$not_attempted" >&2
      else
        echo "    (none)" >&2
      fi
      echo "  Staging dir preserved for retry:" >&2
      echo "    $staging_dir" >&2
      exit 1
    fi
    if [ -n "$written_paths" ]; then
      written_paths="${written_paths}"$'\n'"    ${group_path}"
    else
      written_paths="    ${group_path}"
    fi
    idx=$((idx + 1))
  done

  # On success (all N writes landed): delete the staging dir
  rm -rf "$staging_dir"

  printf '%s' "$plan" | jq '[.[] | {path, project, branchName, storyCount}]'
}

# ============================================================================
# split-detect — the read side of metadata.splitGroup
# ============================================================================
#
# _story_merge_write_project_split (above) stamps every file it emits with a
# self-describing metadata.splitGroup marker. This is the consumer: given a
# scope, it answers "do the tasks files here form ONE group that must execute
# together, and which members still have work?".
#
# It lives here rather than in /aimi:execute's markdown because every rule it
# encodes -- anchor selection, sibling resolution, total validation, active
# filtering, legacy-pair fallback -- is pure, deterministic, file-only logic.
# Written as executable prose it was unreachable by both Bash test suites, and
# it drifted into two divergent copies (flat flow vs. phase mode). Here one
# copy serves both scopes and every rule is a test case.
#
# It is a QUERY, not a gate: every outcome, including "single" and "none",
# exits 0. Non-zero is reserved for real errors (bad argument, unreadable dir).

# A story is pending when its status is anything other than "completed".
# Exactly one definition, used for every count this verb reports. The prose
# it replaces had two that disagreed -- `!= "completed"` for the active filter
# and `== "pending"` for the phase completion count -- so an in_progress story
# was counted by one and not the other, which let a phase close with work
# still in flight.
_SPLIT_DETECT_DESCRIBE_JQ='
  (if type == "object" then . else {} end) as $doc
| (if ($doc.metadata | type) == "object" then $doc.metadata else {} end) as $m
| (if ($m.splitGroup | type) == "object" then $m.splitGroup else {} end) as $sg
| {
    path: $path,
    project: (if ($sg.project | type) == "string" then $sg.project else "." end),
    branchName: (if ($m.branchName | type) == "string" then $m.branchName else null end),
    storyCount: (if ($doc.userStories | type) == "array"
                 then ($doc.userStories | length) else 0 end),
    pendingCount: (if ($doc.userStories | type) == "array"
                   then ([$doc.userStories[]
                          | select((.status? // "pending") != "completed")] | length)
                   else 0 end),
    hasMarker: (($sg.total | type) == "number" and ($sg.siblings | type) == "array"),
    declaredTotal: (if ($sg.total | type) == "number" then ($sg.total | tostring) else "" end),
    siblings: (if ($sg.siblings | type) == "array"
               then [$sg.siblings[] | tostring] else [] end)
  }
| . + {active: (.pendingCount > 0)}
'

# Emit one compact JSON descriptor for a candidate tasks file.
# A file that is unreadable or not valid JSON yields an inert descriptor
# (no marker, no stories) instead of aborting: one corrupt file sitting in
# .aimi/tasks/ must not take detection down for every other feature.
_split_detect_describe() {
  local file="$1"
  local desc=""
  desc=$(jq -c --arg path "$file" "$_SPLIT_DETECT_DESCRIBE_JQ" "$file" 2>/dev/null) || desc=""
  if [ -z "$desc" ]; then
    desc=$(jq -nc --arg path "$file" '{path: $path, project: ".", branchName: null,
      storyCount: 0, pendingCount: 0, hasMarker: false, declaredTotal: "",
      siblings: [], active: false}')
  fi
  printf '%s' "$desc"
}

# List *-tasks.json files directly inside <dir> (depth 1 only), newest mtime
# first. NUL-delimited find -> xargs -0 keeps paths containing spaces intact,
# the same hardening _find_tasks_files_all carries; a newline-delimited
# `xargs ls -t` word-splits them and silently returns nothing.
_split_detect_list_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*-tasks.json' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null || true
}

# Derive the phase's own governing tasks file from a phase directory, so it can
# be excluded from the split candidate pool. Layout is
# .aimi/tasks/<feature>/phase-<N>[.<M>][-<slug>]/<feature>-phase-<N>-tasks.json.
# Prints nothing when <dir> is not shaped like a phase directory (nothing to
# exclude then, which is the safe direction: an extra candidate is still
# filtered by the marker and pair rules below).
_split_detect_phase_main_file() {
  local dir="$1"
  local dir_base feature phase_id
  dir_base=$(basename "$dir")
  case "$dir_base" in
    phase-[0-9]*) ;;
    *) return 0 ;;
  esac
  phase_id=${dir_base#phase-}
  phase_id=${phase_id%%-*}
  case "$phase_id" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  feature=$(basename "$(dirname "$dir")")
  [ -n "$feature" ] || return 0
  printf '%s/%s-phase-%s-tasks.json' "$dir" "$feature" "$phase_id"
}

cmd_split_detect() {
  local scope_dir=""
  local dir_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Error: split-detect: --dir requires a directory path" >&2
          exit 1
        fi
        scope_dir="$2"
        dir_mode=true
        shift 2
        ;;
      *)
        echo "Error: split-detect: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # 1. Build the candidate pool, newest mtime first
  # ------------------------------------------------------------------
  local candidates=""
  local exclude_file=""
  if [ "$dir_mode" = true ]; then
    if [ ! -d "$scope_dir" ]; then
      echo "Error: split-detect: --dir is not a directory: $scope_dir" >&2
      exit 1
    fi
    scope_dir=$(resolve_path "$scope_dir")
    validate_path_in_project "$scope_dir"
    exclude_file=$(_split_detect_phase_main_file "$scope_dir")
    candidates=$(_split_detect_list_dir "$scope_dir")
  else
    # Flat scope is depth 1 ONLY: candidates are the *-tasks.json files whose
    # parent directory is $TASKS_DIR itself. _find_tasks_files_all globs depth
    # 1-3, which includes every phase directory -- and that is exactly how a
    # phase's split files used to be captured by the flat flow and executed as
    # a flat split, leaving the phase unclaimed and nothing merged into the
    # phase branch. The filter below is the fix, and it is load-bearing.
    local all_files=""
    all_files=$(_find_tasks_files_all)
    if [ -n "$all_files" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$(dirname "$f")" = "$TASKS_DIR" ] || continue
        candidates="${candidates}${f}"$'\n'
      done <<< "$all_files"
    fi
  fi

  local pool="[]"
  if [ -n "$candidates" ]; then
    local cand desc
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ -n "$exclude_file" ] && [ "$cand" = "$exclude_file" ] && continue
      desc=$(_split_detect_describe "$cand")
      pool=$(printf '%s' "$pool" | jq -c --argjson d "$desc" '. + [$d]')
    done <<< "$candidates"
  fi

  local started_empty=false
  [ "$(printf '%s' "$pool" | jq 'length')" -eq 0 ] && started_empty=true

  # ------------------------------------------------------------------
  # 2. Resolve the group
  # ------------------------------------------------------------------
  # "Newest wins": the anchor is the newest candidate, not the first
  # marker-carrying file in mtime order. The old rule let a stale marked split
  # from a past feature preempt today's plan whenever today's files carried no
  # marker of their own.
  local mode="none"
  local anchor="null"
  local members="[]"
  local declared_total="0"
  local degraded_reason=""

  # AIMI_ROOT-is-a-git-repo check, computed once. find_aimi_root() already cd'd
  # the process to AIMI_ROOT before cmd_split_detect ever runs (dispatch at
  # line ~9167 happens after the find_aimi_root call at ~9116), and --dir only
  # narrows the candidate pool below -- it never changes CWD. So $PWD here is
  # AIMI_ROOT in both flat and --dir scope, and this is the identical check
  # commands/execute.md documents as the canonical AIMI_ROOT_IS_GIT_REPO rule.
  local aimi_root_is_git=true
  git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1 || aimi_root_is_git=false

  while :; do
    local pool_len=0
    pool_len=$(printf '%s' "$pool" | jq 'length')
    if [ "$pool_len" -eq 0 ]; then
      mode="none"
      if [ "$started_empty" != true ] && [ -z "$degraded_reason" ]; then
        degraded_reason="every candidate group is already fully completed"
      fi
      break
    fi

    local newest newest_path newest_dir newest_marker
    newest=$(printf '%s' "$pool" | jq -c '.[0]')
    newest_path=$(printf '%s' "$newest" | jq -r '.path')
    newest_dir=$(dirname "$newest_path")
    newest_marker=$(printf '%s' "$newest" | jq -r '.hasMarker')

    local group="[]"
    local group_mode=""
    local group_total="0"

    if [ "$newest_marker" = "true" ]; then
      # -- Marked group: the members are the anchor plus its OWN declared
      #    siblings. Nothing else in the pool participates, however similar
      #    its basename. Each sibling resolves BY BASENAME against the
      #    anchor's own directory, which is what renders a traversal-shaped
      #    sibling entry inert: "../../etc/passwd" becomes "<anchor-dir>/passwd",
      #    which does not exist, and the group is voided.
      local anchor_total="" resolve_ok=true bad_detail=""
      anchor_total=$(printf '%s' "$newest" | jq -r '.declaredTotal')
      group="[$newest]"

      case "$anchor_total" in
        ''|*[!0-9]*)
          resolve_ok=false
          bad_detail="declared total is not a whole number: \"${anchor_total}\""
          ;;
      esac

      if [ "$resolve_ok" = true ]; then
        local sib sib_path sib_desc dup
        while IFS= read -r sib; do
          [ -n "$sib" ] || continue
          sib_path="$newest_dir/$(basename "$sib")"
          if [ ! -f "$sib_path" ]; then
            resolve_ok=false
            bad_detail="declared sibling not found in the anchor's directory: $sib_path"
            break
          fi
          dup=$(printf '%s' "$group" | jq -r --arg p "$sib_path" '[.[] | select(.path == $p)] | length')
          if [ "$dup" -ne 0 ]; then
            resolve_ok=false
            bad_detail="declared sibling resolves to a member already in the group: $sib_path"
            break
          fi
          sib_desc=$(_split_detect_describe "$sib_path")
          group=$(printf '%s' "$group" | jq -c --argjson d "$sib_desc" '. + [$d]')
        done <<< "$(printf '%s' "$newest" | jq -r '.siblings[]')"
      fi

      local resolved=0
      resolved=$(printf '%s' "$group" | jq 'length')
      if [ "$resolve_ok" != true ] || [ "$resolved" -ne "$anchor_total" ] || [ "$resolved" -lt 2 ]; then
        # A group that fails validation degrades to single-file execution and
        # is TERMINAL -- it deliberately does not fall through to the legacy
        # pair rule. This scope was planned by the project-split writer, so any
        # -frontend-/-backend-tasks.json sitting beside it is stale, and running
        # it would execute the wrong work.
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        degraded_reason="split group anchored at ${newest_path} is unusable (declared total ${anchor_total:-?}, resolved ${resolved}"
        if [ -n "$bad_detail" ]; then
          degraded_reason="${degraded_reason}; ${bad_detail}"
        fi
        degraded_reason="${degraded_reason}) — degraded to single-file execution, legacy pair not considered"
        break
      fi

      group_mode="project-split"
      group_total="$anchor_total"
    else
      # -- No marker on the newest candidate: try the legacy
      #    -frontend-tasks.json / -backend-tasks.json pair rule over the pool.
      #    The counterpart must be in the pool, not merely on disk, so the
      #    scope (flat depth 1, or this one phase directory) still bounds it.
      local newest_base prefix fe_path be_path
      newest_base=$(basename "$newest_path")
      prefix=""
      fe_path=""
      be_path=""
      case "$newest_base" in
        *-frontend-tasks.json)
          prefix="${newest_base%-frontend-tasks.json}"
          fe_path="$newest_path"
          be_path="$newest_dir/${prefix}-backend-tasks.json"
          ;;
        *-backend-tasks.json)
          prefix="${newest_base%-backend-tasks.json}"
          be_path="$newest_path"
          fe_path="$newest_dir/${prefix}-frontend-tasks.json"
          ;;
      esac

      local counterpart=""
      if [ -n "$prefix" ]; then
        if [ "$fe_path" = "$newest_path" ]; then counterpart="$be_path"; else counterpart="$fe_path"; fi
        local in_pool
        in_pool=$(printf '%s' "$pool" | jq -r --arg p "$counterpart" '[.[] | select(.path == $p)] | length')
        [ "$in_pool" -eq 0 ] && counterpart=""
      fi

      if [ -n "$counterpart" ]; then
        if [ "$aimi_root_is_git" != true ]; then
          # A legacy frontend/backend pair with no metadata.splitGroup marker
          # resolves to the root routing key "." (_SPLIT_DETECT_DESCRIBE_JQ's
          # default at 6459) -- fine in a single-repo layout, but AIMI_ROOT
          # here is not a git repository at all: a parent folder holding
          # multiple git repos as subfolders, with no repository underneath
          # "." to execute in. Refuse instead of binding to it. Reuses the
          # same mode=none-plus-degradedReason shape as the exhausted-pool
          # case above -- no new mode value, no new emitted field.
          mode="none"
          anchor="null"
          members="[]"
          declared_total="0"
          degraded_reason="AIMI_ROOT (${PWD}) is not a git repository — this is a multi-repo layout, a parent folder holding multiple git repositories as subfolders. The legacy pair ${fe_path} / ${be_path} has no metadata.splitGroup marker and would route to the root group \".\", which has no repository to execute in. Re-plan with --split full-stack so every story carries its own project, then re-run."
          break
        fi
        # Frontend first, backend second — the order the two-file writer and
        # every downstream report already assume.
        group=$(printf '%s' "$pool" | jq -c --arg fe "$fe_path" --arg be "$be_path" \
          '[(.[] | select(.path == $fe)), (.[] | select(.path == $be))]')
        group_mode="paired-split"
        group_total="2"
      else
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        break
      fi
    fi

    # A group with nothing left to do is not this run's work. Drop ALL of its
    # members from the pool and look again, rather than letting a completed
    # stale split route today's real work to a single-file fallback.
    local group_active=0
    group_active=$(printf '%s' "$group" | jq '[.[] | select(.active)] | length')
    if [ "$group_active" -eq 0 ]; then
      pool=$(printf '%s\n%s' "$pool" "$group" | jq -sc '
        .[1] as $g | [.[0][] | select(.path as $p | ($g | map(.path) | index($p)) == null)]')
      continue
    fi

    mode="$group_mode"
    anchor=$(printf '%s' "$newest" | jq -c '.path')
    members="$group"
    declared_total="$group_total"
    break
  done

  # ------------------------------------------------------------------
  # 3. Emit
  # ------------------------------------------------------------------
  printf '%s' "$members" | jq \
    --arg mode "$mode" \
    --argjson anchor "$anchor" \
    --argjson total "$declared_total" \
    --arg reason "$degraded_reason" \
    '{
      mode: $mode,
      anchor: $anchor,
      members: [.[] | {path, project, branchName, storyCount, pendingCount, active}],
      activeCount: ([.[] | select(.active)] | length),
      total: $total,
      degradedReason: (if ($reason | length) > 0 then $reason else null end)
    }'
}

# ============================================================================
# Roadmap Lifecycle Subcommands (Phase/Milestone layer for large-scope features)
# ============================================================================
#
# roadmap.json lives at .aimi/tasks/<feature>/roadmap.json and tracks phase
# lifecycle state (pending -> planned -> in_progress -> completed, or ->
# verification_failed) plus PID-alive claims so parallel /aimi:execute
# sessions can safely claim independent phases without hallucinated bash.
# Every write is a locked read-modify-write (mkdir-then-lock-then-tmpfile-
# then-move), mirroring _story_merge_write_legacy. flock is held only for
# the duration of each atomic operation -- never across separate CLI calls.

# Single-path-component pattern for a phase's dir field: phase-N[.M][-slug]
_ROADMAP_DIR_REGEX='^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$'
# Single-path-component pattern for the --feature slug (no slash, no dotdot)
_ROADMAP_FEATURE_REGEX='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
# Reused branchName convention (see plugins/aimi-engineering/CLAUDE.md)
_ROADMAP_BRANCH_REGEX='^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'

# The stored roadmap.json shape every contract READER in this file requires.
#
# It tracks the shape of one creates/needs entry and nothing else -- not the
# CLI version, not the plugin version, not any other roadmap.json field. "1.0"
# means an entry is the single string "identity (description)"; "2.0" means it
# is {identity, description}, two fields judged by two different rules. Bump it
# only when that entry shape changes again, and ship the normalize-contracts
# migration in the same commit.
_ROADMAP_CONTRACT_VERSION="2.0"

# jq `def` spliced into programs that sanitize free-text roadmap fields
# (name, goal, successCriteria entries, notes, branch, brainstormPath).
# Deletes triple-fenced code blocks wholesale, UNWRAPS a single-backtick span
# to its inner text, then strips newlines, "$(" command-substitution openers,
# HTML/XML tags, and common instruction-override phrases, and truncates to
# maxlen. Mirrors commands/references/sanitization.md plus the explicit
# newline/dollar-paren stripping called for in this story's notes.
#
# The span rule unwraps rather than deletes because a backtick is a formatting
# marker, not content: deleting the span took the identity with it, and
# "## Artifacts Created" in handoff.md is exactly what _cv_handoff_lists_artifact
# greps to resolve a later phase's needs, so a deleted identity surfaced as an
# unresolvable contract one phase after its cause. A fenced block is not an
# identity, so the triple-fence rule stays a deletion.
#
# ORDER IS LOAD-BEARING in two places. The fence rule must precede the span rule
# so ``` is consumed as a fence and not as two spans. The span rule must precede
# the newline collapse: its character class excludes \n on purpose, so running it
# after newlines became spaces would let one span straddle what were two lines
# and change which text counts as wrapped.
#
# The lone-backtick strip on the next line is KEPT deliberately. Unwrapping only
# consumes PAIRED markers; an odd or unmatched backtick still reaches it, and
# without it that character would land in output. Two assertions depend on it
# (zero backticks in handoff content, and in story-merge droppedDeps titles).
_ROADMAP_SANITIZE_JQ='
def _rm_sanitize(maxlen):
  if . == null then null else
  ( .
    | gsub("```[\\s\\S]*?```"; "")
    | gsub("`(?<inner>[^`\n]*)`"; .inner)
    | gsub("`"; "")
    | gsub("\r\n|\r|\n"; " ")
    | gsub("\\$\\("; "")
    | gsub("<[^>]*>"; "")
    | gsub("ignore previous( instructions)?"; ""; "i")
    | gsub("you are now"; ""; "i")
    | gsub("(?<b>(^|\\s)[^a-zA-Z0-9]*)system\\s*:"; .b; "i")
    | if (length > maxlen) then .[0:maxlen] else . end
  ) end;

# The INTENDED-mutation prefix of _rm_sanitize: formatting normalization only.
# Fenced blocks go, a backticked span unwraps to its inner text, a stray marker
# goes, newlines collapse, the cap applies -- and nothing else. Every rule
# _rm_sanitize applies beyond this point DELETES CONTENT (an HTML/XML-looking
# tag, "$(", an instruction-override phrase), which is fine for prose but
# rewrites an identity into a token the phase will not deliver.
#
# _roadmap_identity_errors compares the two: same identity, nothing was lost;
# different identity, a content rule fired and the entry is refused rather than
# quietly stored under a name verify-creates will never find. Keep this in step
# with _rm_sanitize -- a new formatting rule belongs in both, a new content rule
# in _rm_sanitize alone.
def _rm_markers_only(maxlen):
  if . == null then null else
  ( .
    | gsub("```[\\s\\S]*?```"; "")
    | gsub("`(?<inner>[^`\n]*)`"; .inner)
    | gsub("`"; "")
    | gsub("\r\n|\r|\n"; " ")
    | if (length > maxlen) then .[0:maxlen] else . end
  ) end;

# The two rulers, applied to MUTATION as well as to judgement. A creates/needs
# entry is "identity (human description)": the identity is the token
# verify-creates greps for literally, and the description is prose that reaches
# a sub-agent prompt. They need opposite treatment, and running one sanitizer
# over the whole string gave the identity the prose treatment.
#
# The identity gets formatting normalization ONLY. The content rules are what
# rewrote "parseList<T>" into "parseList" and "design-system:tokens" into
# "design-tokens" -- silently, with validate-contracts then passing, so
# verify-creates went looking for a name the phase never produces and the
# failure surfaced a whole phase away from its cause. This repository declares
# templated and namespaced identities on purpose (see the identity-kinds test:
# "queue:emails", "Generic<T>", "db/migrations/*.sql"), so destroying them was
# never right and refusing them would not be either. They now survive verbatim.
#
# The description keeps the full sanitizer, unchanged: a tag, an override
# phrase or a "$(" in prose is exactly what those rules exist for.
#
# Nothing here weakens what an identity may CONTAIN. _roadmap_identity_errors
# still refuses whitespace, "..", a leading "/", the shell class and every
# injection pattern -- on the whole entry -- before any of this is stored.
def _rm_sanitize_contract(maxlen):
  if . == null then null else
  ( (_rm_markers_only(maxlen)) as $m
    | ($m | index("(")) as $i
    | (if $i == null then $m else $m[0:$i] end) as $ident
    | (if $i == null then "" else ($m[$i:] | _rm_sanitize(maxlen)) end) as $desc
    | ($ident + $desc)
    | if (length > maxlen) then .[0:maxlen] else . end
  ) end;
'

# Process-liveness probe, ported from guard-runtime-state.py is_alive() (lines 26-34):
# signal-zero kill probe. "No such process" -> not alive. "Exists, no permission
# to signal" -> alive (mirrors ProcessLookupError=False / PermissionError=True).
_is_pid_alive() {
  local pid="$1"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 0 ]; then
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local err
  err=$(kill -0 "$pid" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qi "not permitted"; then
    return 0
  fi
  return 1
}

# Validate --feature is present and a safe single path component.
# $2 is the optional verb label used to prefix the error; it defaults to the
# historical "roadmap" so every pre-existing caller's message is byte-identical.
_roadmap_validate_feature() {
  local feature="$1"
  local label="${2:-roadmap}"
  if [ -z "$feature" ]; then
    echo "Error: $label: --feature <slug> is required" >&2
    exit 1
  fi
  if ! [[ "$feature" =~ $_ROADMAP_FEATURE_REGEX ]]; then
    echo "Error: $label: --feature must be a single path component matching $_ROADMAP_FEATURE_REGEX, got: $feature" >&2
    exit 1
  fi
}

# Compute the roadmap.json path for a feature (absolute, under TASKS_DIR).
_roadmap_path() {
  local feature="$1"
  printf '%s/%s/roadmap.json\n' "$TASKS_DIR" "$feature"
}

# Shared roadmap-verb preamble: resolve the path, validate it's in-project,
# and fail with a verb-prefixed message if the roadmap is missing or malformed.
# Echoes the resolved path on success. Usage:
#   roadmap_path=$(_roadmap_require <verb> <feature> [not-found-suffix] [--skip-malformed])
# not-found-suffix is appended verbatim to the "roadmap not found" message
# (e.g. " (run roadmap-init first)"); pass "" to omit it.
# --skip-malformed omits the malformed-json check (roadmap-release-claim never
# had one; preserved as-is rather than newly introduced here).
# Several callers re-check malformed-ness a second time inside their _lock
# subshell -- that inner check is deliberate (it re-reads under the lock to
# catch a file that turns malformed between this call and lock acquisition)
# and is not replaced by this helper.
_roadmap_require() {
  local verb="$1" feature="$2" suffix="${3:-}" skip_malformed="${4:-}"
  local path
  path=$(_roadmap_path "$feature")
  validate_path_in_project "$path"
  if [ ! -f "$path" ]; then
    echo "Error: $verb: roadmap not found: $path${suffix}" >&2
    exit 1
  fi
  if [ "$skip_malformed" != "--skip-malformed" ]; then
    if ! jq -e . "$path" >/dev/null 2>&1; then
      echo "Error: $verb: malformed roadmap.json: $path" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$path"
}

# Refuse a roadmap whose stored creates/needs entries pre-date
# $_ROADMAP_CONTRACT_VERSION. Callers: every verb that READS a contract.
#   _roadmap_require_contracts <verb> <roadmap_path> <feature>
#
# IT REFUSES, IT DOES NOT SKIP, and that is the whole design of this helper.
# The tempting alternative -- treat an old roadmap as "nothing to check" and
# carry on -- makes validate-contracts answer valid:true about a document it
# never parsed. A gate that reports success for an unread file is worse than
# no gate: the caller acts on the verdict either way, and only one of the two
# outcomes tells them the truth is unknown.
#
# The comparison is the sort -V idiom cmd_validate_tasks already uses for
# schemaVersion, with a "0" floor so an absent or null roadmapVersion sorts
# below every real one and is refused rather than silently accepted. A version
# ABOVE the required one passes: this CLI can read a document a newer CLI
# wrote for as long as the entry shape is compatible, and refusing it here
# would strand a user mid-upgrade for no gain.
_roadmap_require_contracts() {
  local verb="$1" roadmap_path="$2" feature="$3"
  local stored
  stored=$(jq -r '.roadmapVersion // "0"' "$roadmap_path" 2>/dev/null) || stored="0"
  if [ -z "$stored" ] || [ "$stored" = "null" ]; then
    stored="0"
  fi
  if [ "$(printf '%s\n' "$stored" "$_ROADMAP_CONTRACT_VERSION" | sort -V | head -n1)" != "$_ROADMAP_CONTRACT_VERSION" ]; then
    echo "Error: $verb: this roadmap stores creates/needs in the pre-$_ROADMAP_CONTRACT_VERSION form, where one entry is the single string \"identity (description)\". Nothing was read and nothing was checked. Migrate it once, in place:" >&2
    echo "    aimi-cli.sh normalize-contracts --feature $feature" >&2
    echo "The migration is idempotent and computes each identity with the same function every reader used before, so no identity changes by a byte. (found roadmapVersion $stored, need $_ROADMAP_CONTRACT_VERSION)" >&2
    exit 1
  fi
}

# Validate --phase is present and a bare numeric id (int or one-decimal-place).
_roadmap_validate_phase_id() {
  local phase_id="$1"
  local label="$2"
  if [ -z "$phase_id" ] || ! [[ "$phase_id" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: $label: --phase <id> must be a numeric phase id" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Phase ground truth, has-work, and candidate selection
#
# One phase's status per roadmap.json is a claim about a session; what a phase
# still has to DO is a fact on disk, in its own tasks file. These three pieces
# turn that fact into the ordering both selectors use.
# ---------------------------------------------------------------------------

# Classify a phase from its own tasks file's story statuses. This is
# roadmap-reconcile's original inline expression, lifted verbatim so reconcile
# and the has-work map below cannot drift into two different answers about the
# same file. Callers guarantee the file exists and parses.
_ROADMAP_GROUND_TRUTH_JQ='
  [.userStories[].status] as $statuses |
  if ($statuses | length) == 0 then "unknown"
  elif ($statuses | all(. == "completed")) then "completed"
  elif ($statuses | any(. == "failed")) then "verification_failed"
  else "in_progress"
  end
'

# Emit {"<phase id>": <has work bool>} for every phase in a roadmap.
#   $1 roadmap.json path   $2 feature slug
#
# A phase has NO work only when its own tasks file exists, parses, holds at
# least one story, and every story is "completed" -- i.e. exactly when the
# classification above says "completed". Every other case is has-work:
#   - no tasks file: a pending phase /aimi:plan has not expanded yet. Demoting
#     a phase for being unplanned would rank the whole front of the roadmap
#     last, which is the opposite of the intent.
#   - unparseable: nothing is known, so nothing is demoted.
#   - zero userStories ("unknown"): same reasoning reconcile already applies --
#     it declines to correct a status from an empty story list.
_roadmap_has_work_map() {
  local roadmap_path="$1" feature="$2"
  local feature_dir hw_id hw_dir hw_file hw_truth hw_map
  feature_dir=$(dirname "$roadmap_path")
  hw_map='{}'

  while IFS=$'\t' read -r hw_id hw_dir; do
    [ -z "$hw_id" ] && continue
    hw_file="$feature_dir/$hw_dir/$feature-phase-$hw_id-tasks.json"
    hw_truth="unknown"
    if [ -f "$hw_file" ] && jq -e . "$hw_file" >/dev/null 2>&1; then
      hw_truth=$(jq -r "$_ROADMAP_GROUND_TRUTH_JQ" "$hw_file")
    fi
    if [ "$hw_truth" = "completed" ]; then
      hw_map=$(printf '%s' "$hw_map" | jq --arg k "$hw_id" '. + {($k): false}')
    else
      hw_map=$(printf '%s' "$hw_map" | jq --arg k "$hw_id" '. + {($k): true}')
    fi
  done < <(jq -r '.phases[] | [(.id|tostring), .dir] | @tsv' "$roadmap_path")

  printf '%s' "$hw_map"
}

# The single dependency-eligibility + ordering implementation, spliced into
# both roadmap-get --next-eligible and roadmap-claim's auto-mode branch so the
# two cannot drift apart again. Takes the phases array, the allowed status set,
# and the has-work side map; returns the eligible candidates in claim order.
#
# The caller supplies the array it wants judged, and that is deliberate: it is
# the second axis on which the two selectors differ. roadmap-claim passes
# $cleared_phases (dead-PID claims already nulled, inside its own flock);
# roadmap-get --next-eligible passes .phases raw, because it holds no lock and
# clearing stale claims is a decision that belongs where the lock is. So a
# phase held by a dead session stays claimable by one and invisible to the
# other, exactly as before -- unifying the ordering was never meant to change
# that, and a read-only verb has no business inferring liveness.
#
# ORDER, not the set, was the defect (issue #90). Two jq hazards live in the
# rank helper, both of which silently make the ranking a no-op:
#   - `$work[$k] // true` is wrong: `//` fires on false as well as null, so
#     every legitimate false collapses to true and nothing is ever demoted.
#   - `$work | has(.id|tostring)` is wrong: the pipe rebinds `.` to $work, so
#     `.id` is null and every lookup misses.
# Binding the key first and testing has() explicitly avoids both.
_ROADMAP_SELECT_JQ='
def _rm_rank($work):
  (.id|tostring) as $k
  | if ($work | has($k)) then (if $work[$k] then 0 else 1 end) else 0 end;

def _rm_candidates($phases; $allowed; $work):
  (reduce $phases[] as $p ({}; . + {($p.id|tostring): $p.status})) as $status_by_id
  | [ $phases[]
      # `.status` is bound BEFORE the pipe into $allowed. Written the obvious
      # way -- `$allowed | index(.status)` -- the pipe rebinds `.` to $allowed
      # and jq dies with "Cannot index array with string". Same hazard as the
      # rank helper above, different expression.
      | select(.status as $st | ($allowed | index($st)) != null)
      | select(.claim == null)
      | select(((.dependsOn // []) | all(. as $d | $status_by_id[$d|tostring] == "completed")))
    ]
  | sort_by([_rm_rank($work), .id]);
'

# Read a phases JSON array on stdin; print one human-readable error line per
# creates[]/needs[] entry whose *identity* can never name a real artifact.
#
# The rule is deliberately narrow -- exactly five shapes are rejected, judged
# over the identity (text before the first "(", trimmed) and nothing else:
#   (a) empty after _cv_identity
#   (b) a ".." PATH SEGMENT, i.e. (^|/)\.\.($|/) -- not any byte pair "..",
#       so an identity like services/foo..bar is untouched
#   (c) a leading "/" anchored at position 0 -- the Endpoint kind
#       ("POST /api/notifications") contains a slash but does not begin with
#       one, so anchoring matters or every endpoint phase becomes unwritable
#   (d) whitespace in the token verify-creates will actually SEARCH, judged
#       after the same METHOD-space-slash strip verify-creates step 2 performs
#       (see _roadmap_reject_unfindable_identity below)
#   (e) a shell metacharacter from _cv_shell_class -- the class [$`;|&] that
#       validate-contracts reads through _cv_shell_chars -- so the writer and
#       the reader consult one table rather than two that overlap by accident
# Identity *strength* is explicitly not judged: at declaration time research has
# not run, so a bare Table name ("notifications") or a bare directory
# ("db/migrations") must pass -- guessing a path here fails at phase close for a
# reason nobody can debug.
#
# Why (d) is whitespace and not something richer. verify-creates has exactly two
# ways to find an artifact: a tracked pathspec, and a fixed-string `git grep -F`
# over tracked non-doc non-test source. A token carrying an interior space can
# only match source that literally holds that space-separated phrase.
# Identifiers, paths, table names and route literals never do. The only thing
# that CAN hold it is prose -- a comment or a string -- and documentation is
# already excluded, so a whitespace-bearing identity is either unfindable or,
# worse, findable only in a comment. That is not a heuristic about English; it
# is a statement about what the search can return.
#
# The two things (d) deliberately does NOT catch, so nobody reads it as a
# guarantee of verifiability:
#   * a hyphen-joined prose phrase ("forge-command-surface-in-aimi-cli") --
#     an author who wants to write prose can defeat the rule trivially;
#   * a single token that will simply never exist ("cmd_forge_nonexistent").
# Existence cannot be checked at declaration time -- the artifact has not been
# built yet. The rule proves the identity is the KIND of string a search can
# resolve, never that it will resolve.
#
# The accepted false positive: an honest artifact whose name contains a space
# ("src/My Component.tsx"). It is refusable and the author's only workaround is
# to rename the file. That is the deliberate trade -- see
# commands/references/scope-contexts.md, which teaches the rule and its limit.
#
# Why (e) judges the IDENTITY and not the whole entry. Before it existed the two
# sides disagreed twice over. The writer let ";" "|" "&" and a lone "$" through
# untouched while validate-contracts refused that whole class, so roadmap-init
# wrote phases its own contract gate then hard-failed; and the reader judged the
# RAW entry, so a semicolon anywhere in the parenthesised human description
# killed an identity that was itself clean ("cmd_clean (does x; then y)").
# Both sides now judge the same text -- the identity carries the class ban and
# the description does not -- which is also what verify-creates has always done:
# it searches by identity alone, so a check scoped to anything wider was talking
# about a different string than the search it guards.
#
# The description nevertheless KEEPS validate-contracts' injection half
# (ignore previous / system: / INSTRUCTIONS / code fences / "$("), because it is
# not human-only prose: /aimi:plan collects every completed phase's handoff.md
# into phaseHandoffBlocks (grep that symbol in commands/plan.md) and threads it verbatim
# into every story-expander sub-agent prompt (grep phaseHandoffBlocks in
# commands/plan.md; line numbers there drift). Freeing the description of the
# character class is a legibility fix; freeing it of the injection patterns
# would reopen a prompt-injection path that is closed today.
#
# EXACTLY ONE of the five class characters cannot reach (e): the backtick.
# _rm_sanitize_contract runs over creates/needs first in both callers, and its
# marker-normalization half unwraps a backticked span and drops a stray marker,
# so no backtick survives into a stored identity. The other four -- ";" "|" "&"
# and "$" -- all arrive here and are all refused.
#
# "$(" is NOT a sixth class member and never was: it is a two-character
# SEQUENCE, and the class member it starts with, "$", reaches this rule like any
# other. Counting it as a member is what made an earlier draft of this comment
# say "two of the five", which is wrong by one and reads as though a "$" were
# somehow exempt. It is not.
#
# RETROACTIVITY IS THE CALLER'S PROPERTY, NOT THIS HELPER'S. Nothing here scopes
# anything; this judges every phase object it is handed. Existing roadmaps stay
# readable only because every caller hands over just the phases IT writes:
# roadmap-init passes the whole payload in creation mode but only filtered_new
# under --sync (phases whose ids are not already on disk), and
# cmd_roadmap_amend_phase passes the id plus only the lists that call amends.
# A caller that hands over a stored phase wholesale would retroactively refuse
# roadmaps already written -- this repository's own phases 2, 3 and 4 carry
# whitespace-bearing creates today.
#
# creates[] and needs[] go through the same predicate in the same pass on
# purpose: _cv_creates_in_scope matches a need against a provider's creates by
# exact byte equality, so a rule applied to one list alone lets a roadmap hold
# two shapes at once -- validate-contracts then reports a permanently unmet
# need, which halts /aimi:plan, and agent mode never demotes an unmet need.
#
# Reuses $_CONTRACT_JQ_DEFS so the guard and validate-contracts agree on what an
# identity is; a second copy of _cv_identity would drift.
cmd_roadmap_init() {
  local feature="" file="" sync_mode=false brainstorm_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      --sync) sync_mode=true ;;
      --brainstorm-path) shift; brainstorm_path="${1:-}" ;;
      *)
        echo "Error: roadmap-init: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_path "$feature")
  validate_path_in_project "$roadmap_path"

  # --- Read the phases array from --file or stdin ---
  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-init: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  # --- Everything that must be judged BEFORE the lock ---------------------
  # The split is not cosmetic: today an invalid payload never reaches the
  # mkdir -p below, so a refusal creates no feature directory. Validating
  # inside the lock would create one as a side effect of saying no.
  check_python3
  local new_phases
  new_phases=$(printf '%s' "$input_json" | python3 "$(_aimi_roadmap_py)" init-validate) || exit $?

  mkdir -p "$(dirname "$roadmap_path")"

  # --- Locked read-modify-write: existence/--sync check, additive merge, atomic write ---
  local sync_flag=""
  [ "$sync_mode" = true ] && sync_flag="--sync"
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      printf '%s' "$new_phases" | python3 "$(_aimi_roadmap_py)" init-write \
        --roadmap "$roadmap_path" --feature "$feature" \
        --brainstorm-path "$brainstorm_path" $sync_flag
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# roadmap-amend-phase — correct an existing phase's contract after the fact
# ============================================================================
#
# roadmap-init writes a phase's contract exactly once, at creation, and --sync's
# anti-clobber guarantee leaves an existing phase byte-for-byte alone. That is
# deliberate, and it leaves a phase whose creates/needs/goal/successCriteria/
# areas/branch turn out wrong with no sanctioned writer at all -- while
# guard-runtime-state.py intercepts a Write/Edit on roadmap.json and redirects
# the caller to "the roadmap-* verbs". This verb is what makes that redirect
# truthful.
#
cmd_roadmap_amend_phase() {
  local feature="" phase_id="" file="" goal_flag="" branch_flag=""
  local have_goal=false have_branch=false
  local retarget_pairs='[]'
  local pair pair_old pair_new

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      --goal) shift; goal_flag="${1:-}"; have_goal=true ;;
      --branch) shift; branch_flag="${1:-}"; have_branch=true ;;
      --retarget-needs)
        shift
        pair="${1:-}"
        case "$pair" in
          *=*) ;;
          *)
            echo "Error: roadmap-amend-phase: --retarget-needs expects \"<old identity>=<new identity>\", got: $pair" >&2
            exit 1
            ;;
        esac
        # Split on the FIRST "=" only: an identity may legitimately contain one.
        pair_old="${pair%%=*}"
        pair_new="${pair#*=}"
        if [ -z "$pair_old" ] || [ -z "$pair_new" ]; then
          echo "Error: roadmap-amend-phase: --retarget-needs requires a non-empty identity on both sides of the first \"=\", got: $pair" >&2
          exit 1
        fi
        retarget_pairs=$(printf '%s' "$retarget_pairs" | jq -c --arg o "$pair_old" --arg n "$pair_new" '. + [{old: $o, new: $n}]')
        ;;
      *)
        echo "Error: roadmap-amend-phase: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature" "roadmap-amend-phase"
  _roadmap_validate_phase_id "$phase_id" "roadmap-amend-phase"

  # --- Resolve the amendment payload -------------------------------------
  # --file wins. Otherwise stdin is read only when no scalar flag was given, so
  # `--goal <text>` on its own never blocks waiting for an EOF nobody will send.
  local payload='{}'
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-amend-phase: --file not found: $file" >&2
      exit 1
    fi
    payload=$(cat "$file")
  elif [ "$have_goal" != true ] && [ "$have_branch" != true ]; then
    payload=$(cat)
  fi

  if [ -z "${payload//[[:space:]]/}" ]; then
    payload='{}'
  fi

  # --- Everything judged BEFORE the lock ----------------------------------
  # Same split, and for the same reason, as roadmap-init: a refusal must not
  # take the lock and must not touch the file.
  check_python3
  local goal_args=() branch_args=()
  [ "$have_goal" = true ] && goal_args=(--goal "$goal_flag")
  [ "$have_branch" = true ] && branch_args=(--branch "$branch_flag")
  local sanitized
  sanitized=$(printf '%s' "$payload" | python3 "$(_aimi_roadmap_py)" amend-validate \
    "${goal_args[@]}" "${branch_args[@]}") || exit $?

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-amend-phase" "$feature")

  # --- Locked read-modify-write ------------------------------------------
  # Bash holds the lock; roadmap.py does the whole read-modify-write inside it.
  # Every refusal still happens before the file is touched, so a refused
  # amendment leaves roadmap.json byte-for-byte unchanged.
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      printf '%s' "$sanitized" | python3 "$(_aimi_roadmap_py)" amend-write \
        --roadmap "$roadmap_path" --feature "$feature" --phase "$phase_id" \
        --retargets "$retarget_pairs"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_get() {
  local feature="" phase_id="" next_eligible=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --next-eligible) next_eligible=true ;;
      *)
        echo "Error: roadmap-get: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-get" "$feature")

  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "roadmap-get"
    if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
      echo "Error: roadmap-get: phase $phase_id not found in $roadmap_path" >&2
      exit 1
    fi
    jq --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path"
    return 0
  fi

  if [ "$next_eligible" = true ]; then
    # Same selection implementation roadmap-claim's auto branch uses, narrowed
    # to the two statuses this verb reports. `.phases` is passed raw: this verb
    # holds no lock, so it never clears stale dead-PID claims (see the note on
    # _ROADMAP_SELECT_JQ). Reading one tasks file per phase is new cost for a
    # verb that previously touched only roadmap.json, and it is unsynchronized
    # -- a tasks file rewritten mid-read yields "has work", the safe answer,
    # since only an all-completed file demotes anything.
    local eligible has_work
    has_work=$(_roadmap_has_work_map "$roadmap_path" "$feature")
    eligible=$(jq --argjson work "$has_work" "$_ROADMAP_SELECT_JQ"'
      _rm_candidates(.phases; ["pending","planned"]; $work) | (.[0] // null)
    ' "$roadmap_path")
    if [ "$eligible" = "null" ]; then
      echo "Error: roadmap-get: no eligible phase found" >&2
      exit 1
    fi
    printf '%s\n' "$eligible"
    return 0
  fi

  cat "$roadmap_path"
}

cmd_roadmap_set_status() {
  local feature="" phase_id="" new_status="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --status) shift; new_status="${1:-}" ;;
      --force) force=true ;;
      *)
        echo "Error: roadmap-set-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-set-status"

  case "$new_status" in
    pending|planned|in_progress|completed|verification_failed) ;;
    *)
      echo "Error: roadmap-set-status: --status must be one of pending|planned|in_progress|completed|verification_failed, got: $new_status" >&2
      exit 1
      ;;
  esac

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-set-status" "$feature")

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-set-status: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      current_status=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .status) // empty' "$roadmap_path")
      if [ -z "$current_status" ]; then
        echo "Error: roadmap-set-status: phase $phase_id not found in $roadmap_path" >&2
        exit 1
      fi

      # verification_failed is reachable from any non-terminal state (execute
      # sets it when creates-verification fails). The rest of the graph:
      #   pending -> planned            plan expands the phase
      #   pending -> in_progress        execute claims a phase whose planned
      #                                 transition was lost (plan aborted after
      #                                 writing tasks.json but before setting
      #                                 planned) -- allowing it makes execute
      #                                 self-healing instead of silently
      #                                 diverging from roadmap.json
      #   planned -> in_progress        normal start
      #   in_progress -> in_progress    idempotent resume of a crashed session
      #   verification_failed -> in_progress   re-verify retry
      #   in_progress|verification_failed -> completed
      allowed=false
      if [ "$new_status" = "verification_failed" ]; then
        allowed=true
      else
        case "$current_status:$new_status" in
          pending:planned|pending:in_progress|planned:in_progress|in_progress:in_progress|verification_failed:in_progress|in_progress:completed|verification_failed:completed) allowed=true ;;
        esac
      fi

      if [ "$allowed" != true ] && [ "$force" != true ]; then
        echo "Error: roadmap-set-status: transition $current_status -> $new_status is not allowed without --force" >&2
        exit 1
      fi

      # Hard rule, not an --force-able ordering convention: a phase can never
      # reach "completed" without handoff.md already on disk at its phase dir
      # (see outline 11). handoff.md is written only via roadmap-write-handoff,
      # which is the guard-protected path guard-runtime-state.py points callers
      # at. This check runs even when --force is set -- --force overrides
      # transition *order*, never this physical artifact precondition.
      if [ "$new_status" = "completed" ]; then
        phase_dir=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
        feature_dir=$(dirname "$roadmap_path")
        if [ ! -f "$feature_dir/$phase_dir/handoff.md" ]; then
          echo "Error: roadmap-set-status: phase $phase_id cannot transition to completed -- no handoff.md found at $feature_dir/$phase_dir/handoff.md. Write it first with roadmap-write-handoff." >&2
          exit 1
        fi
      fi

      # Completing a phase also releases its claim in the same atomic write --
      # no window where status reads completed while the phase still shows
      # claimed (see outline 11; mirrors cmd_mark_complete's single-write pattern).
      if [ "$new_status" = "completed" ]; then
        roadmap_doc=$(jq --argjson pid "$phase_id" --arg status "$new_status" '
          .phases |= map(if .id == $pid then .status = $status | .claim = null else . end)
        ' "$roadmap_path")
      else
        roadmap_doc=$(jq --argjson pid "$phase_id" --arg status "$new_status" '
          .phases |= map(if .id == $pid then .status = $status else . end)
        ' "$roadmap_path")
      fi

      tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
      printf '%s\n' "$roadmap_doc" > "$tmp_file"
      mv "$tmp_file" "$roadmap_path"

      jq -n --argjson pid "$phase_id" --arg from "$current_status" --arg to "$new_status" '{phase: $pid, from: $from, to: $to}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_claim() {
  local feature="" session_id="" session_pid="" phase_override=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --session-id) shift; session_id="${1:-}" ;;
      --session-pid) shift; session_pid="${1:-}" ;;
      --phase) shift; phase_override="${1:-}" ;;
      *)
        echo "Error: roadmap-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -z "$session_id" ]; then
    echo "Error: roadmap-claim: --session-id <id> is required" >&2
    exit 1
  fi
  if ! [[ "$session_pid" =~ ^[0-9]+$ ]]; then
    echo "Error: roadmap-claim: --session-pid <pid> must be a positive integer" >&2
    exit 1
  fi
  if [ -n "$phase_override" ]; then
    _roadmap_validate_phase_id "$phase_override" "roadmap-claim"
  fi
  # Sanitize the caller-supplied session id before it is ever written to roadmap.json.
  session_id=$(printf '%s' "$session_id" | jq -Rr "$_ROADMAP_SANITIZE_JQ"'_rm_sanitize(200)')

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-claim" "$feature" " (run roadmap-init first)")

  # --phase is a bare numeric id at this point (validated above); pass it through
  # to jq as a number, or JSON null when no override was given.
  local phase_override_json="null"
  [ -n "$phase_override" ] && phase_override_json="$phase_override"

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-claim: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      # Identify stale claims (claimedPid no longer alive) inside this locked pass.
      # sessionId travels alongside pid here so the release report line below
      # ("released stale claim on phase <id> (session <sid> pid <pid> not
      # alive)") can be built without a second read of roadmap.json.
      # _is_pid_alive is a bash kill(2) probe, not something jq can do, so
      # the loop itself stays bash -- but it only accumulates plain phase-id
      # lines while the lock is held, then converts them to a JSON array in
      # one jq pass at the end, instead of spawning one jq process per stale
      # claim to grow the array incrementally.
      claimed_pids=$(jq -c '[.phases[] | select(.claim != null) | {id: .id, pid: .claim.claimedPid, sessionId: .claim.claimedBy}]' "$roadmap_path")
      stale_id_lines=""
      while IFS=$'\t' read -r pid_phase_id pid_val; do
        [ -z "$pid_phase_id" ] && continue
        if ! _is_pid_alive "$pid_val"; then
          stale_id_lines="${stale_id_lines}${pid_phase_id}"$'\n'
        fi
      done < <(printf '%s' "$claimed_pids" | jq -r '.[] | [(.id|tostring), (.pid|tostring)] | @tsv')
      stale_ids=$(printf '%s' "$stale_id_lines" | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)')
      stale_released=$(printf '%s' "$claimed_pids" | jq --argjson stale_ids "$stale_ids" '
        [.[] | select((.id) as $id | ($stale_ids | index($id)) != null)]
      ')

      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      # Has-work pre-pass, inside this same lock, so the ordering below reads a
      # tasks-file snapshot no concurrent claim can move under it. It is a SIDE
      # MAP handed to jq as one --argjson, never a field merged onto the phase
      # objects: $cleared_phases is the very array written back to roadmap.json
      # at the end of this function, so a synthetic key added here would be
      # persisted forever and would then flow into validate-contracts,
      # roadmap-sweep and roadmap-reconcile.
      has_work=$(_roadmap_has_work_map "$roadmap_path" "$feature")

      result=$(jq -n \
        --slurpfile cur "$roadmap_path" \
        --argjson stale_ids "$stale_ids" \
        --argjson stale_released "$stale_released" \
        --arg session_id "$session_id" \
        --arg now "$now" \
        --argjson session_pid "$session_pid" \
        --argjson phase_override "$phase_override_json" \
        --argjson work "$has_work" \
        "$_ROADMAP_SELECT_JQ"'
          ($cur[0]) as $current |
          ($current.phases | map(if ((.id) as $id | ($stale_ids | index($id)) != null) then .claim = null else . end)) as $cleared_phases |
          (reduce $cleared_phases[] as $p ({}; . + {($p.id|tostring): $p.status})) as $status_by_id |
          # Self-reclaim: this exact session already owns an unreleased claim on a
          # still-active phase (matching the requested --phase when given). Return
          # it again instead of erroring or re-running eligibility -- this is what
          # makes re-running /aimi:execute on an already-claimed phase idempotent.
          ($cleared_phases | map(select(
            .claim != null and .claim.claimedBy == $session_id and
            (.status == "pending" or .status == "planned" or .status == "in_progress") and
            ($phase_override == null or .id == $phase_override)
          ))) as $self_claimed |
          (if ($self_claimed | length) > 0 then
            ($self_claimed | sort_by(.id) | .[0]) as $mine |
            {claimed: true, phase: $mine, phases: $cleared_phases}
          elif $phase_override != null then
            ($cleared_phases | map(select(.id == $phase_override))) as $target_arr |
            if ($target_arr | length) == 0 then
              {claimed: false, reason: "phase-not-found", phases: null}
            else
              ($target_arr[0]) as $target |
              if ((["pending","planned","in_progress","verification_failed"] | index($target.status)) == null) then
                {claimed: false, reason: "not-claimable", detail: ("phase status is " + $target.status), phases: null}
              elif $target.claim != null then
                {claimed: false, reason: "claimed", detail: "claimed by a live session", phases: null}
              elif ((($target.dependsOn // []) | all(. as $d | $status_by_id[$d|tostring] == "completed")) | not) then
                {claimed: false, reason: "blocked", detail: ("depends on incomplete phase(s): " + ((($target.dependsOn // []) | map(select($status_by_id[(.|tostring)] != "completed")) | map(tostring) | join(", ")))), phases: null}
              else
                ($cleared_phases | map(if .id == $target.id then . + {claim: {claimedBy: $session_id, claimedAt: $now, claimedPid: $session_pid}} else . end)) as $final_phases |
                {claimed: true, phase: ($final_phases[] | select(.id == $target.id)), phases: $final_phases}
              end
            end
          else
            # Resumable = not yet terminal AND carrying no live claim. Stale
            # claims were already cleared above, so an unclaimed in_progress
            # phase is leftover from a crashed session and verification_failed
            # is awaiting a re-verify run -- both must be re-claimable or crash
            # recovery and verification retry are dead ends, which is exactly
            # what execute.md tells the user to recover by re-running.
            #
            # The ORDER within that set, not the set itself, was issue #90. A
            # stuck phase is by construction older and therefore lower-id than
            # whatever came after it, so plain sort_by(.id) made it win every
            # auto-claim indefinitely, ahead of the phase genuinely ready to
            # run. Candidates are now ranked by remaining work first and id
            # second. Ranking DEMOTES, it never excludes: the moment a zero-work
            # phase is the only eligible candidate it is claimed, which is what
            # keeps crash recovery and the verification retry reachable.
            (_rm_candidates($cleared_phases; ["pending","planned","in_progress","verification_failed"]; $work)) as $eligible |
            if ($eligible | length) > 0 then
              ($eligible | .[0]) as $chosen |
              ($cleared_phases | map(if .id == $chosen.id then . + {claim: {claimedBy: $session_id, claimedAt: $now, claimedPid: $session_pid}} else . end)) as $final_phases |
              {claimed: true, phase: ($final_phases[] | select(.id == $chosen.id)), phases: $final_phases}
            else
              ($cleared_phases | map(select(.status == "pending" or .status == "planned" or .status == "in_progress" or .status == "verification_failed"))) as $remaining |
              if ($remaining | length) == 0 then
                {claimed: false, reason: "none-eligible", phases: null}
              else
                ($remaining | map(
                  if .claim != null then
                    {id: .id, reason: ("claimed by session " + .claim.claimedBy)}
                  else
                    {id: .id, reason: ("depends on incomplete phase(s): " + (((.dependsOn // []) | map(select($status_by_id[(.|tostring)] != "completed")) | map(tostring) | join(", "))))}
                  end
                )) as $blocked_reasons |
                {claimed: false, reason: "all-blocked", blocked: $blocked_reasons, phases: null}
              end
            end
          end) as $outcome |
          # INTERNAL envelope, never stdout. This attaches staleReleased to the
          # $outcome wrapper ({claimed, phase, phases, reason...}) that the bash
          # below destructures. Actual stdout is the SECOND `+ {staleReleased`
          # further down -- `.phase + {staleReleased: .staleReleased}` -- and
          # that one is the claim envelope execute.md Step 1.7 reads
          # .id/.dir/.slug/.branch/.status off. So a grep for `+ {staleReleased`
          # returns two hits, and always has; only the lower one is a contract.
          # Projecting it would silently disable the re-verify branch in
          # execute.md Step 3, which is why test-aimi-cli.sh pins all six of
          # those fields on the auto path.
          $outcome + {staleReleased: $stale_released}
        ')

      claimed=$(printf '%s' "$result" | jq -r '.claimed')

      if [ "$claimed" = "true" ]; then
        new_phases_out=$(printf '%s' "$result" | jq '.phases')
        roadmap_doc=$(jq --argjson phases "$new_phases_out" '.phases = $phases' "$roadmap_path")

        tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
        printf '%s\n' "$roadmap_doc" > "$tmp_file"
        mv "$tmp_file" "$roadmap_path"

        printf '%s' "$result" | jq '.phase + {staleReleased: .staleReleased}'
        exit 0
      fi

      reason=$(printf '%s' "$result" | jq -r '.reason')
      case "$reason" in
        none-eligible)
          echo "Error: roadmap-claim: no phase remains in pending, planned, in_progress or verification_failed status" >&2
          exit 4
          ;;
        phase-not-found)
          echo "Error: roadmap-claim: phase $phase_override not found in $roadmap_path" >&2
          exit 4
          ;;
        not-claimable|claimed|blocked)
          detail=$(printf '%s' "$result" | jq -r '.detail')
          echo "Error: roadmap-claim: phase $phase_override is not claimable: $detail" >&2
          exit 3
          ;;
        *)
          echo "Error: roadmap-claim: all remaining pending/planned phases are blocked:" >&2
          printf '%s' "$result" | jq -r '.blocked[] | "  phase " + (.id|tostring) + ": " + .reason' >&2
          exit 3
          ;;
      esac
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_release_claim() {
  local feature="" phase_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      *)
        echo "Error: roadmap-release-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-release-claim"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-release-claim" "$feature" "" --skip-malformed)

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-release-claim: phase $phase_id not found in $roadmap_path" >&2
        exit 1
      fi

      roadmap_doc=$(jq --argjson pid "$phase_id" '
        .phases |= map(if .id == $pid then .claim = null else . end)
      ' "$roadmap_path")

      tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
      printf '%s\n' "$roadmap_doc" > "$tmp_file"
      mv "$tmp_file" "$roadmap_path"

      jq -n --argjson pid "$phase_id" '{released: $pid}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_reconcile() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      *)
        echo "Error: roadmap-reconcile: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-reconcile" "$feature")

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-reconcile: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      phase_dirs=$(jq -c '[.phases[] | {id: .id, dir: .dir, status: .status}]' "$roadmap_path")
      corrections='[]'

      blocked='[]'

      while IFS=$'\t' read -r rc_id rc_dir rc_status; do
        [ -z "$rc_id" ] && continue
        # Phase tasks files follow <feature>-phase-<id>-tasks.json (the same
        # convention phase-overlap, execute.md Step 1.7, plan.md Phase 3e and
        # status.md use). Reading a bare tasks.json here made every lookup miss,
        # so reconcile silently reported zero corrections.
        rc_tasks_file="$feature_dir/$rc_dir/$feature-phase-$rc_id-tasks.json"
        if [ ! -f "$rc_tasks_file" ]; then
          continue
        fi
        if ! jq -e . "$rc_tasks_file" >/dev/null 2>&1; then
          continue
        fi
        # Shared with the has-work map roadmap-claim ranks on
        # (_ROADMAP_GROUND_TRUTH_JQ) -- one rule, so the two cannot disagree
        # about the same tasks file.
        ground_truth=$(jq -r "$_ROADMAP_GROUND_TRUTH_JQ" "$rc_tasks_file")
        if [ "$ground_truth" != "unknown" ] && [ "$ground_truth" != "$rc_status" ]; then
          # Same hard precondition roadmap-set-status enforces: a phase never
          # reaches "completed" without handoff.md on disk. Reconcile must not
          # be a second write path with weaker invariants -- an otherwise-valid
          # completed correction is reported as blocked instead of applied, so
          # the divergence stays visible rather than silently healed wrong.
          if [ "$ground_truth" = "completed" ] && [ ! -f "$feature_dir/$rc_dir/handoff.md" ]; then
            blocked=$(printf '%s' "$blocked" | jq --argjson id "$rc_id" --arg from "$rc_status" --arg to "$ground_truth" \
              '. + [{id: $id, from: $from, to: $to, reason: "no handoff.md -- write it with roadmap-write-handoff, then re-run"}]')
          else
            corrections=$(printf '%s' "$corrections" | jq --argjson id "$rc_id" --arg from "$rc_status" --arg to "$ground_truth" '. + [{id: $id, from: $from, to: $to}]')
          fi
        fi
      done < <(printf '%s' "$phase_dirs" | jq -r '.[] | [(.id|tostring), .dir, .status] | @tsv')

      if [ "$(printf '%s' "$corrections" | jq 'length')" -gt 0 ]; then
        # Reaching "completed" also releases the claim in the same atomic write,
        # mirroring roadmap-set-status -- otherwise a reconciled phase reads as
        # done while still showing claimed by a dead session.
        roadmap_doc=$(jq --argjson corr "$corrections" '
          .phases |= map(
            . as $p |
            (($corr | map(select(.id == $p.id)) | .[0]) // null) as $c |
            if $c != null then
              ($p + {status: $c.to} | if $c.to == "completed" then .claim = null else . end)
            else $p end
          )
        ' "$roadmap_path")

        tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
        printf '%s\n' "$roadmap_doc" > "$tmp_file"
        mv "$tmp_file" "$roadmap_path"
      fi

      jq -n --argjson corr "$corrections" --argjson blocked "$blocked" '{corrections: $corr, blocked: $blocked}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Write a phase's handoff.md through a guard-protected CLI call (see outline
# 11). guard-runtime-state.py blocks any direct Write/Edit tool call whose
# target is .aimi/tasks/<feature>/phase-N/handoff.md and points the caller
# back at this verb -- this is the only path that may create or overwrite
# that file. Reads a JSON object from --file or stdin with five optional
# array-of-string fields (decisions, artifacts, deviations, deferred,
# contracts); each entry is sanitized and length-capped with the same
# _rm_sanitize regime as every other free-text roadmap field. Always emits
# exactly five "## " headings in the fixed order
# "Decisions Made" / "Artifacts Created" / "Deviations" / "Deferred Items" /
# "Contracts Delivered" -- the order roadmap-set-status's completed-requires-
# handoff precondition and _cv_handoff_lists_artifact's "Artifacts Created"
# lookup both depend on. Overwrites any existing handoff.md at that path
# (idempotent retry after a verification_failed -> completed re-run).
cmd_roadmap_write_handoff() {
  local feature="" phase_id="" file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      *)
        echo "Error: roadmap-write-handoff: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-write-handoff"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-write-handoff" "$feature")

  local phase_dir
  phase_dir=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
  if [ -z "$phase_dir" ]; then
    echo "Error: roadmap-write-handoff: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-write-handoff: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  if ! printf '%s' "$input_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: roadmap-write-handoff: payload must be a JSON object" >&2
    exit 1
  fi

  local key
  for key in decisions artifacts deviations deferred contracts; do
    if ! printf '%s' "$input_json" | jq -e --arg k "$key" '(.[$k] // []) as $v | ($v|type) == "array" and ($v | all(type == "string"))' >/dev/null 2>&1; then
      echo "Error: roadmap-write-handoff: field '$key' must be an array of strings" >&2
      exit 1
    fi
  done

  # The identities this phase declared, read through _cv_identity itself and
  # never a second copy of the split rule -- the two must not drift.
  #
  # WHY THIS FUNCTION NEEDS THEM. "## Artifacts Created" is exactly what
  # _cv_handoff_lists_artifact greps to resolve a later phase's needs, and this
  # verb was running the full prose sanitizer over the artifacts it renders.
  # Measured: creates ["parseList<T> (a generic helper)"] is stored verbatim in
  # roadmap.json and lands in handoff.md as "parseList", so validate-contracts
  # reports {"need":"parseList<T>","reason":"not-delivered"} forever. The tag
  # rule is right for prose and wrong for a token that is grepped literally --
  # the same two-rulers split roadmap-init already makes, one boundary later.
  local declared_ids
  declared_ids=$(jq -c --argjson pid "$phase_id" "$_CONTRACT_JQ_DEFS"'
    [ .phases[] | select(.id == $pid) | (.creates // [])[] | _cv_identity ]
  ' "$roadmap_path" 2>/dev/null) || declared_ids='[]'
  [ -n "$declared_ids" ] || declared_ids='[]'

  local body
  body=$(printf '%s' "$input_json" | jq -r --argjson ids "$declared_ids" "$_ROADMAP_SANITIZE_JQ"'
    def clean: map(_rm_sanitize(2000));

    # Prose sanitizer, except that a declared identity at the head of the line
    # survives byte-for-byte. Longest match wins so a phase declaring both
    # "alpha" and "alphabet" keeps the longer one whole. A line matching no
    # declared identity is ordinary prose and gets the full treatment.
    def clean_delivery: map(
      . as $line
      # ". as $i" first, deliberately: inside "select($line | startswith(.))"
      # the pipe rebinds "." to $line, so the test becomes
      # "$line startswith $line" -- true for every id, and the longest declared
      # identity is then spliced onto a line it does not begin. This file warns
      # about that exact rebinding twice elsewhere ($work | has(.id|tostring),
      # $allowed | index(.status)); it caught this function too, in review.
      | ([ $ids[] | . as $i | select($line | startswith($i)) ] | sort_by(length) | last) as $id
      | if $id == null then ($line | _rm_sanitize(2000))
        else $id + ($line[($id | length):] | _rm_sanitize(2000)) end
      | if (length > 2000) then .[0:2000] else . end
    );
    def section(title; items):
      "## " + title + "\n\n" +
      (if (items | length) == 0 then "_None._\n" else ((items | map("- " + .)) | join("\n")) + "\n" end);
    {
      decisions: ((.decisions // []) | clean),
      artifacts: ((.artifacts // []) | clean_delivery),
      deviations: ((.deviations // []) | clean),
      deferred: ((.deferred // []) | clean),
      contracts: ((.contracts // []) | clean_delivery)
    } as $s |
    section("Decisions Made"; $s.decisions) + "\n" +
    section("Artifacts Created"; $s.artifacts) + "\n" +
    section("Deviations"; $s.deviations) + "\n" +
    section("Deferred Items"; $s.deferred) + "\n" +
    section("Contracts Delivered"; $s.contracts)
  ')

  local feature_dir handoff_path
  feature_dir=$(dirname "$roadmap_path")
  handoff_path="$feature_dir/$phase_dir/handoff.md"
  validate_path_in_project "$handoff_path"

  # Tripwire, before the write. Every declared identity a payload line claimed
  # to deliver must still be findable, byte-for-byte, in the rendered body --
  # under the same fixed-string match _cv_handoff_lists_artifact uses to resolve
  # a downstream needs.
  #
  # With the renderer above this can never fire, and that is the point: it is
  # not a check on today's code, it is a guard against a future sanitizer edit
  # silently reopening the defect this commit closes. Refusing beats writing a
  # handoff that reads complete and resolves nothing a phase later. It only
  # judges identities some line actually claimed, so a phase reporting fewer
  # artifacts than it declared -- a legitimate partial delivery -- is untouched.
  local lost_ids
  lost_ids=$(printf '%s' "$input_json" | jq -r --argjson ids "$declared_ids" --arg body "$body" '
    ((.artifacts // []) + (.contracts // [])) as $lines
    | [ $ids[]
        | . as $id
        | select(any($lines[]; startswith($id)))
        | select(($body | contains($id)) | not) ]
    | .[]
  ')
  if [ -n "$lost_ids" ]; then
    echo "Error: roadmap-write-handoff: the rendered handoff lost a declared identity it was asked to report:" >&2
    printf '  %s\n' $lost_ids >&2
    echo "Error: roadmap-write-handoff: '## Artifacts Created' is what validate-contracts greps to resolve a downstream needs, so writing this would leave that contract permanently unmet. Nothing was written." >&2
    exit 1
  fi

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      mkdir -p "$(dirname "$handoff_path")"
      tmp_file=$(mktemp "${handoff_path}.XXXXXX")
      printf '%s\n' "$body" > "$tmp_file" && mv "$tmp_file" "$handoff_path"
      jq -n --arg path "$handoff_path" '{handoff: $path}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# Contract Validation Subcommands (validate-contracts, roadmap-sweep)
# ============================================================================
# Cross-check a feature's roadmap.json creates[]/needs[] contracts: an unmet
# need (no phase in the needing phase's dependsOn closure creates it) and a
# duplicate creates (the same artifact identity declared by two or more
# phases). Artifact identity is the substring before a creates/needs entry's
# first "(", trimmed of surrounding whitespace (see outline 01's shared
# scope-context reference).
#
# Schema note: the roadmap phase status enum is pending/planned/in_progress/
# completed/verification_failed (see cmd_roadmap_set_status above) -- there
# is no "deferred" status. roadmap-sweep's deferredNeeds check substitutes
# the existing "provider resolved but status != completed" signal for the
# undefined "deferred" status value, per this story's authoritative notes
# reconciling the schema gap against outline 02/outline 14.

# jq `def`s shared by validate-contracts and roadmap-sweep -- and, for
# _cv_identity and _cv_shell_class, by _roadmap_identity_errors' write-time
# guard, so the writer and the reader cannot drift apart on what an identity is
# or which characters an identity may not hold.
#
# _cv_suspicious is deliberately two halves with two different scopes. The full
# argument for why -- and why the description keeps the injection guard -- lives
# in commands/references/scope-contexts.md, "Two rulers". In short:
#   * _cv_injection judges the WHOLE raw entry, description included, because a
#     description reaches a story-expander sub-agent prompt via /aimi:plan's
#     phaseHandoffBlocks (grep that symbol; do not cite line numbers here, they
#     drift).
#   * The shell class judges only the IDENTITY (_cv_identity: the text before
#     the first "(", trimmed) -- the token verify-creates greps and every
#     contract match keys on. Applying it to the raw entry refused
#     "cmd_clean (does x; then y)", an identity that is itself clean.
#
# Both instruction markers anchor on POSITION -- start-of-string or whitespace,
# then any run of punctuation -- because that is what a marker looks like and
# what an ordinary name never does. The full rule and its rationale live in
# commands/references/scope-contexts.md, "Two rulers"; this comment records only
# why the shape is what it is, because both directions have already been wrong.
#
#   Too wide: unanchored, "INSTRUCTIONS" matched the ordinary English word, so
#   "docs/instructions.md (setup instructions)" was written by roadmap-init and
#   then refused by validate-contracts. The same unanchored "system:" matched
#   inside "design-system:tokens".
#
#   Too narrow: keying on the neighbouring character ([^a-zA-Z0-9_-]) and
#   requiring a colon after INSTRUCTIONS closed those two and admitted
#   "--system: do this" and "### INSTRUCTIONS do X" -- a hyphen is an identifier
#   character, and a heading needs no colon.
#
# The heading form requires the "#" deliberately: without it an artifact
# legitimately named INSTRUCTIONS.md would be refused. Keep this in step with
# _rm_sanitize's own "system:" strip, which uses the same anchor. Both tables in
# test-aimi-cli-part3-roadmap-forge.sh guard this pair -- widening fails the
# ordinary rows, narrowing fails the injection rows.
#
# The shell-class half is written as a cheap necessary condition first:
# an identity is a trimmed prefix of the raw entry, so a class character in the
# identity implies one in the entry. Testing the raw entry first lets the common
# case (a clean entry) skip _cv_identity's sub()+gsub() entirely.
#
# _roadmap_identity_errors rejects both halves at write time, so this reader
# check is defence in depth and should not be the place authors meet the rule.
_CONTRACT_JQ_DEFS='
def _cv_identity: sub("\\(.*"; "") | gsub("^[ \t]+|[ \t]+$"; "");
def _cv_shell_class: "[$`;|&]";
def _cv_injection: test("ignore previous|(^|\\s)[^a-zA-Z0-9]*system\\s*:|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b|INSTRUCTIONS\\s*:|```|\\$\\("; "i");
def _cv_suspicious:
  _cv_injection
  or (test(_cv_shell_class) and (_cv_identity | test(_cv_shell_class)));
'

# ============================================================================
# normalize-contracts — migrate stored creates/needs from 1.0 to 2.0
# ============================================================================
#
# 1.0 stores one entry as the string "identity (description)"; 2.0 stores
# {identity, description}. This verb is the only writer of that transition, and
# it exists rather than "just regenerate the roadmap" because roadmaps live
# outside this repository too -- a phases array is authored once, by hand or by
# /aimi:brainstorm, and re-deriving one loses every amendment made since.
#
# THE CORRECTNESS ARGUMENT IS THAT IT CALLS _cv_identity, NOT A COPY OF IT.
# Every reader in this file has always computed the identity as
# `sub("\\(.*"; "")` then trim. A migration that re-derived that split with its
# own regex would be a fourth ruler, and any disagreement -- even on one entry
# in one roadmap -- silently repoints a downstream needs at nothing, because
# needs are matched against creates by exact byte equality. Reusing the
# function makes the migrated identity byte-identical to what the pre-migration
# readers saw, by construction rather than by testing.
#
# It therefore does NOT judge. A whitespace-bearing prose identity the current
# writer would refuse migrates unchanged; the reader gate is what surfaces it
# afterwards, in a diagnostic that names the entry. Repairing on the way past
# would silently change what a phase promises.
#
# _nc_description is the exact inverse of _cv_identity's sub(): everything from
# the first "(" on, minus one leading "(" and one trailing ")". An entry with
# no "(" at all yields "" -- absent description, not null, so no reader needs a
# string-or-null branch.
cmd_normalize_contracts() {
  local feature=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature)
        feature="${2:-}"
        shift 2
        ;;
      *)
        echo "Error: normalize-contracts: unknown argument: $1" >&2
        echo "Usage: aimi-cli.sh normalize-contracts --feature <slug>" >&2
        exit 1
        ;;
    esac
  done

  _roadmap_validate_feature "$feature" "normalize-contracts"
  local roadmap_path
  roadmap_path=$(_roadmap_require normalize-contracts "$feature" " (run roadmap-init first)")

  check_python3
  # Bash holds the lock; roadmap.py does the whole read-modify-write inside it,
  # including the re-read that catches a file which turned malformed between
  # _roadmap_require's check and lock acquisition. One crossing, not four.
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" normalize-contracts --roadmap "$roadmap_path"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Print newline-separated phase ids reachable via transitive dependsOn
# closure from $2 (excluding $2 itself). $1 = roadmap_path.
_cv_reachable_ids() {
  local roadmap_path="$1" start_id="$2"
  jq -r --argjson start "$start_id" '
    (reduce .phases[] as $p ({}; . + {($p.id|tostring): ($p.dependsOn // [])})) as $deps |
    def _cv_expand($cur): ($cur + ($cur | map($deps[(.|tostring)] // []) | add // [])) | unique;
    ([$start] | until(_cv_expand(.) == .; _cv_expand(.))) - [$start] | .[]
  ' "$roadmap_path"
}

# Print "id<TAB>identity<TAB>status<TAB>dir" for every creates[] entry of
# every phase whose id is in the given newline-separated id list ($2),
# sorted by phase id ascending (deterministic first-match order for
# provider lookup). $1 = roadmap_path.
_cv_creates_in_scope() {
  local roadmap_path="$1" ids_input="$2"
  local ids_json='[]'
  if [ -n "$ids_input" ]; then
    ids_json=$(printf '%s\n' "$ids_input" | jq -R 'select(length > 0) | tonumber' | jq -s '.')
  fi
  jq -r --argjson ids "$ids_json" "$_CONTRACT_JQ_DEFS"'
    [.phases[] | select(.id as $i | $ids | index($i) != null)] | sort_by(.id) | .[] |
    . as $p | ((.creates // [])[]? | _cv_identity) as $ident |
    "\($p.id)\t\($ident)\t\($p.status)\t\($p.dir // "")"
  ' "$roadmap_path"
}

# True (exit 0) when handoff.md at $1 lists artifact identity $2 under an
# "Artifacts Created" section (any heading level). Fixed-string match (-F)
# so an identity containing regex metacharacters cannot alter the search.
_cv_handoff_lists_artifact() {
  local handoff_path="$1" identity="$2"
  [ -f "$handoff_path" ] || return 1
  awk '
    /^#+[ \t]+Artifacts Created/ { flag=1; next }
    /^#+[ \t]/ { flag=0 }
    flag { print }
  ' "$handoff_path" | grep -qF -- "$identity"
}

# ============================================================================
# verify-creates — prove a phase's creates[] exist in code, not in prose
# ============================================================================
#
# The whole rule lives in roadmap.py: the ':(glob)' pathspec, the 27-entry
# exclusion list, the endpoint-prefix strip, the TODO/FIXME marker rejection and
# the git exit-code ladder that separates "the phase did not build it" from "we
# could not look". It moved there because every one of those pathspecs carries
# ':', '*' and '(' -- characters a shell is free to reinterpret -- and the
# pathspec defect this verb was fixed for came from exactly that. An argument
# list has no quoting layer to get wrong.
#
# Verified against 24 captured cases before the jq was deleted: every documented
# identity kind, the doc and test exclusions, the marker rejection, an empty
# repository, and the three pathspec-magic forms. 72 of 72 field comparisons
# identical. tests/golden_from_jq.json keeps them.

cmd_verify_creates() {
  local feature="" phase_id="" dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase)   shift; phase_id="${1:-}" ;;
      --dir)     shift; dir="${1:-}" ;;
      *)
        echo "Error: verify-creates: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "verify-creates"

  local roadmap_path
  roadmap_path=$(_roadmap_require "verify-creates" "$feature")

  if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
    echo "Error: verify-creates: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  # --dir is the phase container's absolute path. It defaults to PROJECT_ROOT
  # rather than erroring, so the only --dir failure is a path that is not a
  # directory (or escapes the project).
  if [ -z "$dir" ]; then
    dir="$PROJECT_ROOT"
  fi
  if [ ! -d "$dir" ]; then
    echo "Error: verify-creates: --dir is not a directory: $dir" >&2
    exit 1
  fi
  dir=$(resolve_path "$dir")
  validate_path_in_project "$dir"

  check_python3
  python3 "$(_aimi_roadmap_py)" verify-creates \
    --roadmap "$roadmap_path" --phase "$phase_id" --dir "$dir"
}

cmd_validate_contracts() {
  local feature="" phase_id="" agent_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        shift; phase_id="${1:-}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      -*)
        echo "Usage: aimi-cli.sh validate-contracts <feature> [--phase <id>] [--agent-mode]" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "validate-contracts"
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "validate-contracts" "$feature")
  if [ -n "$phase_id" ] && ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
    echo "Error: validate-contracts: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  # --- Sanitization pass: always blocks; never demoted by --agent-mode ---
  # (a duplicate-creates finding is the only check this story demotes)
  # One line per offending ENTRY, naming the entry and why -- not one line per
  # (phase, field) saying only "suspicious content". This is the diagnostic an
  # author actually reaches when a stored roadmap trips the reader, and it used
  # to be the least informative message in the system while the write-time guard
  # one screen up named the entry, the character and the remedy. Same shape as
  # _roadmap_identity_errors, deliberately: the two are the same rule, and a
  # reader who has seen one should recognise the other.
  local sanitize_hits
  sanitize_hits=$(jq -r "$_CONTRACT_JQ_DEFS"'
    [.phases[] | . as $p |
      ("creates","needs") as $field |
      (($p[$field] // []) | to_entries[]) as $e |
      select($e.value | type == "string") |
      select($e.value | _cv_suspicious) |
      (($e.value | _cv_identity | [match(_cv_shell_class) | .string] | first) // null) as $char |
      (if $char != null
         then "its identity carries the shell metacharacter \"" + $char + "\", which verify-creates cannot grep for"
         else "it matches an instruction-injection pattern (ignore previous / system: / INSTRUCTIONS: / code fence / \"$(\")"
       end) as $reason |
      "phase \($p.id) field '"'"'\($field)'"'"' entry #\($e.key + 1): \($reason)"
    ] | unique | .[]
  ' "$roadmap_path")
  if [ -n "$sanitize_hits" ]; then
    while IFS= read -r hit_line; do
      [ -z "$hit_line" ] && continue
      echo "Error: validate-contracts: $hit_line" >&2
    done <<< "$sanitize_hits"
    echo "Error: validate-contracts: roadmap-init and roadmap-amend-phase refuse these at write time, so a roadmap this CLI wrote should not reach here. Repair with: roadmap-amend-phase --feature <slug> --phase <id>" >&2
    exit 1
  fi

  # --- Duplicate-creates collision check (across all phases, any status) ---
  local dup_check dup_count
  dup_check=$(jq "$_CONTRACT_JQ_DEFS"'
    [.phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident | {identity: $ident, phase: $p.id}]
    | group_by(.identity)
    | map(select(length > 1))
    | map({identity: .[0].identity, phases: ([.[].phase] | unique | sort)})
  ' "$roadmap_path")
  dup_count=$(printf '%s' "$dup_check" | jq 'length')

  if [ "$dup_count" -gt 0 ]; then
    local dup_msg
    dup_msg=$(printf '%s' "$dup_check" | jq -r '
      .[] | "  phase " + (.phases | map(tostring) | join(" and phase ")) +
      ": both declare \"" + .identity + "\" -- convert the collision into a" +
      " creates/needs contract between the two phases or promote the" +
      " artifact to a shared foundation phase"
    ')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: validate-contracts: duplicate creates (--agent-mode: proceeding):" >&2
      printf '%s\n' "$dup_msg" >&2
    else
      echo "Error: validate-contracts: duplicate creates:" >&2
      printf '%s\n' "$dup_msg" >&2
      exit 1
    fi
  fi

  # --- Needs resolution: scope is --phase (if given) or every phase ---
  local scope_ids
  if [ -n "$phase_id" ]; then
    scope_ids=$(jq --argjson pid "$phase_id" -r '.phases[] | select(.id == $pid) | .id' "$roadmap_path")
  else
    scope_ids=$(jq -r '.phases[].id' "$roadmap_path")
  fi

  local missing_json='[]'
  local providers_json='{}'

  local sid
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue

    local reach_ids creates_tsv
    reach_ids=$(_cv_reachable_ids "$roadmap_path" "$sid")
    creates_tsv=$(_cv_creates_in_scope "$roadmap_path" "$reach_ids")

    local need_ident
    while IFS= read -r need_ident; do
      [ -z "$need_ident" ] && continue

      local prov_line
      prov_line=$(printf '%s\n' "$creates_tsv" | awk -F'\t' -v want="$need_ident" '$2 == want { print; exit }')

      if [ -z "$prov_line" ]; then
        missing_json=$(printf '%s' "$missing_json" | jq --argjson pid "$sid" --arg need "$need_ident" '. + [{phase: $pid, need: $need, reason: "no-provider"}]')
        continue
      fi

      local prov_id prov_status prov_dir
      IFS=$'\t' read -r prov_id _ prov_status prov_dir <<< "$prov_line"

      if [ -z "$phase_id" ]; then
        # Unscoped run: identity resolution within the dependsOn closure is
        # sufficient; the completed+handoff delivery gate only applies when
        # --phase pins the check to one phase's execution readiness.
        providers_json=$(printf '%s' "$providers_json" | jq --arg k "$need_ident" --argjson v "$prov_id" '. + {($k): $v}')
        continue
      fi

      local delivered=false
      if [ "$prov_status" = "completed" ] && _cv_handoff_lists_artifact "$feature_dir/$prov_dir/handoff.md" "$need_ident"; then
        delivered=true
      fi

      if [ "$delivered" = "true" ]; then
        providers_json=$(printf '%s' "$providers_json" | jq --arg k "$need_ident" --argjson v "$prov_id" '. + {($k): $v}')
      else
        missing_json=$(printf '%s' "$missing_json" | jq --argjson pid "$sid" --arg need "$need_ident" '. + [{phase: $pid, need: $need, reason: "not-delivered"}]')
      fi
    done < <(jq -r --argjson pid "$sid" "$_CONTRACT_JQ_DEFS"'.phases[] | select(.id == $pid) | (.needs // [])[] | _cv_identity' "$roadmap_path")
  done < <(printf '%s\n' "$scope_ids")

  local valid_bool="true"
  if [ "$(printf '%s' "$missing_json" | jq 'length')" -gt 0 ]; then
    valid_bool="false"
  fi

  if [ "$dup_count" -gt 0 ] && [ "$agent_mode" = "true" ]; then
    jq -n --argjson valid "$valid_bool" --argjson missing "$missing_json" --argjson providers "$providers_json" --argjson dupw "$dup_check" \
      '{valid: $valid, missing: $missing, providers: $providers, duplicateWarnings: $dupw}'
  else
    jq -n --argjson valid "$valid_bool" --argjson missing "$missing_json" --argjson providers "$providers_json" \
      '{valid: $valid, missing: $missing, providers: $providers}'
  fi

  if [ "$valid_bool" = "false" ]; then
    exit 1
  fi
  exit 0
}

# phase-overlap <feature> <phase-a> <phase-b>
# Stage 2 of the sibling-phase overlap guard (execute.md calls this only after
# its own stage-1 roadmap.json `areas` comparison finds a non-empty coarse
# intersection). Loads both phases' already-expanded tasks.json files, unions
# each phase's userStories[].implementation.files, and prints the sorted,
# deduplicated intersection as {"overlapping_files": [...]}.
cmd_phase_overlap() {
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if [ "${#positional[@]}" -ne 3 ]; then
    echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
    exit 1
  fi

  local feature="${positional[0]}" phase_a="${positional[1]}" phase_b="${positional[2]}"

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_a" "phase-overlap"
  _roadmap_validate_phase_id "$phase_b" "phase-overlap"

  if [ "$phase_a" = "$phase_b" ]; then
    echo "Error: phase-overlap: phase-a and phase-b must differ, got $phase_a twice" >&2
    exit 1
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "phase-overlap" "$feature" " (run roadmap-init first)")

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  local dir_a dir_b
  dir_a=$(jq -r --argjson pid "$phase_a" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
  dir_b=$(jq -r --argjson pid "$phase_b" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")

  if [ -z "$dir_a" ]; then
    echo "Error: phase-overlap: phase $phase_a not found in $roadmap_path" >&2
    exit 1
  fi
  if [ -z "$dir_b" ]; then
    echo "Error: phase-overlap: phase $phase_b not found in $roadmap_path" >&2
    exit 1
  fi

  # Mirrors execute.md Step 1.7's PHASE_TASKS_PATH convention:
  # <feature_dir>/<phase_dir>/<feature>-phase-<id>-tasks.json
  local tasks_a tasks_b
  tasks_a="$feature_dir/$dir_a/$feature-phase-$phase_a-tasks.json"
  tasks_b="$feature_dir/$dir_b/$feature-phase-$phase_b-tasks.json"

  if [ ! -f "$tasks_a" ]; then
    echo "Error: phase-overlap: phase $phase_a has no tasks file yet ($tasks_a) -- run /aimi:plan --phase $phase_a to materialize it first" >&2
    exit 1
  fi
  if [ ! -f "$tasks_b" ]; then
    echo "Error: phase-overlap: phase $phase_b has no tasks file yet ($tasks_b) -- run /aimi:plan --phase $phase_b to materialize it first" >&2
    exit 1
  fi
  if ! jq -e . "$tasks_a" >/dev/null 2>&1; then
    echo "Error: phase-overlap: malformed tasks file: $tasks_a" >&2
    exit 1
  fi
  if ! jq -e . "$tasks_b" >/dev/null 2>&1; then
    echo "Error: phase-overlap: malformed tasks file: $tasks_b" >&2
    exit 1
  fi

  jq -n --slurpfile a "$tasks_a" --slurpfile b "$tasks_b" '
    ([$a[0].userStories[]?.implementation.files[]?] | unique) as $files_a |
    ([$b[0].userStories[]?.implementation.files[]?] | unique) as $files_b |
    {overlapping_files: ([$files_a[] | select(. as $f | $files_b | index($f) != null)] | unique | sort)}
  '
}

cmd_roadmap_sweep() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh roadmap-sweep <feature>" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-sweep" "$feature")

  # Single-pass, advisory-only computation: never exits non-zero. Suspicious
  # creates/needs entries are dropped from $clean_phases before orphan/deferred
  # computation so a flagged entry can never leak into any other output field.
  #
  # The DROP IS REPORTED, not silent. A dropped creates entry is invisible to
  # the orphan/deferred analysis that follows, so a downstream phase whose needs
  # cited it reads as unmet with no trace of why -- exactly the phase-late,
  # cause-far-away failure this contract exists to remove. Each warning now
  # carries droppedCount and the offending entries, so a reader can tell
  # "nothing declared it" apart from "it was declared and then discarded here".
  jq "$_CONTRACT_JQ_DEFS"'
    (
      [.phases[] | . as $p |
        ("creates","needs") as $field |
        (($p[$field] // []) | to_entries | map(select(.value | type == "string" and _cv_suspicious))) as $bad |
        select(($bad | length) > 0) |
        {phase: $p.id, field: $field,
         message: "contains suspicious content -- dropped from this sweep, so anything downstream that cited it now reads as unmet",
         droppedCount: ($bad | length),
         droppedIndexes: ($bad | map(.key + 1))}
      ] | unique_by([.phase,.field])
    ) as $warnings |

    (.phases | map(
      .creates = ((.creates // []) | map(select(_cv_suspicious | not))) |
      .needs = ((.needs // []) | map(select(_cv_suspicious | not)))
    )) as $clean_phases |

    ([$clean_phases[] | (.needs // [])[] | _cv_identity] | unique) as $need_idents |
    ([$clean_phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident |
      select(($need_idents | index($ident)) == null) |
      {phase: $p.id, creates: $ident}
    ]) as $orphan_creates |

    ([$clean_phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident | {identity: $ident, phase: $p.id, status: $p.status}]) as $providers_flat |
    ([$clean_phases[] | . as $np | (($np.needs // [])[] | _cv_identity) as $ident |
      ([$providers_flat[] | select(.identity == $ident)] | sort_by(.phase) | .[0]) as $prov |
      select($prov != null and $prov.status != "completed") |
      {phase: $np.id, need: $ident, deferred: $prov.phase}
    ]) as $deferred_needs |

    {orphanCreates: $orphan_creates, deferredNeeds: $deferred_needs, warnings: $warnings}
  ' "$roadmap_path"

  exit 0
}

# ============================================================================
# Payload Budget Estimation (advisory; Phase/Milestone Roadmap Layer)
# ============================================================================
#
# estimate-payload is purely advisory per the brainstorm's "budget as
# validator, not cutting criterion" decision: it never blocks planning and
# never trims content itself. Its only job is to print a clear warning with
# an actionable next step when a phase's context payload risks overflowing
# the sub-agent context window.

# Portable byte-size lookup (GNU stat -c%s, BSD/macOS stat -f%z fallback).
_file_size_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

# Resolve the effective payload budget in bytes plus the fraction it
# represents of the 400000-byte reference sub-agent window. --budget-bytes
# is a manual debug escape hatch (no caller passes it; plan.md's only
# caller uses the default); everything else defaults to 50% of the
# reference window.
# Usage: _estimate_payload_resolve_budget <flag_bytes>
# Prints "<budgetBytes> <budgetFraction>" (space-separated) on stdout.
_estimate_payload_resolve_budget() {
  local flag_bytes="$1"
  local reference_window=400000

  local bytes="" fraction=""

  if [ -n "$flag_bytes" ]; then
    bytes="$flag_bytes"
  else
    fraction="0.5"
  fi

  if [ -n "$bytes" ]; then
    fraction=$(jq -n --argjson b "$bytes" --argjson r "$reference_window" '$b / $r')
  else
    bytes=$(jq -n --argjson f "$fraction" --argjson r "$reference_window" '(($r * $f) | floor)')
  fi

  printf '%s %s\n' "$bytes" "$fraction"
}

# Sum the byte sizes of --outline (required) plus every repeated --research,
# --spec, and --prototype path, and report whether the total fits within the
# effective budget. Always exits 0 for valid input (advisory only); exits 1
# only on usage errors (missing --outline, a given path that does not exist).
cmd_estimate_payload() {
  local outline="" budget_bytes_flag=""
  local research_paths=() spec_paths=() prototype_paths=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --outline) shift; outline="${1:-}" ;;
      --research) shift; research_paths+=("${1:-}") ;;
      --spec) shift; spec_paths+=("${1:-}") ;;
      --prototype) shift; prototype_paths+=("${1:-}") ;;
      --budget-bytes) shift; budget_bytes_flag="${1:-}" ;;
      *)
        echo "Error: estimate-payload: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -z "$outline" ]; then
    echo "Error: estimate-payload: --outline <path> is required" >&2
    echo "Usage: aimi-cli.sh estimate-payload --outline <path> [--research <path>]... [--spec <path>]... [--prototype <path>]... [--budget-bytes <n>]" >&2
    exit 1
  fi
  if [ ! -f "$outline" ]; then
    echo "Error: estimate-payload: File not found: $outline" >&2
    exit 1
  fi

  local outline_bytes research_bytes=0 spec_bytes=0 prototype_bytes=0
  outline_bytes=$(_file_size_bytes "$outline")

  local p
  for p in "${research_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    research_bytes=$((research_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${spec_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    spec_bytes=$((spec_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${prototype_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    prototype_bytes=$((prototype_bytes + $(_file_size_bytes "$p")))
  done

  local total_bytes=$((outline_bytes + research_bytes + spec_bytes + prototype_bytes))

  local budget_line budget_bytes budget_fraction
  budget_line=$(_estimate_payload_resolve_budget "$budget_bytes_flag")
  budget_bytes=$(printf '%s' "$budget_line" | cut -d' ' -f1)
  budget_fraction=$(printf '%s' "$budget_line" | cut -d' ' -f2)

  local over_budget=false
  local warning="null"
  if [ "$total_bytes" -gt "$budget_bytes" ]; then
    over_budget=true
    warning='"Payload exceeds budget -- split the phase along a semantic seam in the roadmap, or trim research/prototype scope."'
  fi

  jq -n \
    --argjson total "$total_bytes" \
    --argjson outline "$outline_bytes" \
    --argjson research "$research_bytes" \
    --argjson specs "$spec_bytes" \
    --argjson prototypes "$prototype_bytes" \
    --argjson budgetBytes "$budget_bytes" \
    --argjson budgetFraction "$budget_fraction" \
    --argjson overBudget "$over_budget" \
    --argjson warning "$warning" \
    '{
      totalBytes: $total,
      breakdown: {outline: $outline, research: $research, specs: $specs, prototypes: $prototypes},
      budgetBytes: $budgetBytes,
      budgetFraction: $budgetFraction,
      overBudget: $overBudget,
      warning: $warning
    }'
}

# Display help
cmd_help() {
  cat << 'EOF'
aimi-cli.sh - Deterministic task file operations for Aimi

USAGE:
    aimi-cli.sh <command> [args]

COMMANDS:
    init-session              Initialize execution session, save state
    find-tasks                Find most recent tasks file
    status [--counts-only]    Get status summary as JSON
                              --counts-only  Return aggregate counts without userStories array
    metadata                  Get metadata only
    next-story                Get next pending story, save to state
    current-story             Get currently active story from state
    list-ready [--brief]      List stories ready to execute (dependency-aware)
                              --brief  Return only {id, title, priority, dependsOn} per story
    mark-in-progress <id>     Mark story as in_progress (returns {id, status} JSON)
    mark-complete <id>        Mark story as completed (returns {id, status} JSON)
    mark-failed <id> [notes]  Mark story as failed (returns {id, status, notes} JSON)
    mark-skipped <id>         Mark story as skipped (returns {id, status} JSON)
    set-execution-mode <container|inline>
                              Persist a --container/--inline override onto metadata.execution
                              (returns {execution} JSON). Refuses with non-zero exit on a
                              phase-scoped tasks file (metadata.phase present).
    count-pending             Count pending stories
    validate-deps             Validate dependency graph (no cycles, no missing refs)
    validate-stories          Validate story content (length, suspicious patterns)
    normalize-verification <file>
                              Rewrite any story whose verification is a bare string S
                              into {strategy: S, status: "pending", url: null, expect: null}.
                              Already-object verifications are left unchanged.
                              Writes atomically (tmp + mv). Exits 0 on success.
    normalize-status <file>   Default any story missing the status field to "pending".
                              Already-set status values are preserved (uses //= operator).
                              Writes atomically (tmp + mv). Exits 0 on success.
                              Reports count of stories with status field after heal.
    validate-ids              Validate all story IDs match US-NNN format
    gate-pass <id> [--option 'value']
                              Pass a gate on a story; optionally store selected option
    gate-fail <id>            Fail a gate on a story
    update-field <id> <field.path> <value>
                              Update a nested field on a story (e.g., verification.status passed)
    validate-waves            Compute waves from dependsOn, compare to stored wave, report mismatches
    validate-tasks            Validate tasks file citation fields (schemaVersion guard, no checks yet)
    cascade-skip <id>         Skip all stories depending on failed story
    reset-orphaned            Reset all in_progress stories to failed
    get-branch                Get branchName from metadata
    get-story <id>            Get full story object by ID (read-only)
    get-story-context <id>    Get story slice + metadata + skills[] + designContext as JSON
                              (for subagent self-brief). Output keys: story, metadata, skills,
                              designContext. skills[] contains {name, path, content} per
                              declared skill. designContext contains {decisions, bundleGuidance}.
    get-state                 Get all state files as JSON
    detect-default-branch [--project <path>]
                              Detect and cache the repository's default branch
    detect-parent-branch <branch> [--project <path>]
                              Detect branch's parent (base) branch by token-aware
                              git log decoration parsing + git merge-base verification.
                              Output: {branch, base, verified, source
                              ("decoration"|"default-branch")}. Falls back to the
                              default branch (unverified) when no decoration
                              candidate survives normalization or merge-base check.
    detect-forge [--project <path>]
                              Classify the active git remote's hostname into
                              github|gitlab|gitea|unknown (exact-or-subdomain,
                              port-aware). Output: {forge, host, remote,
                              remoteUrl, source ("override"|"remote"|
                              "no-remote"|"ambiguous-remotes")}. Set
                              AIMI_FORGE_TYPE=github|gitlab|gitea to override
                              detection entirely (source=override, no git
                              remote read runs); any other value exits 1.
                              Never cached -- re-derived on every invocation.
    forge-auth-status [--project <path>]
                              Report whether the active forge session is authenticated
                              and which account it is acting as. Output:
                              {status ("found"|"error"), data, message}. data (when
                              found) carries {forge, host, authenticated, account,
                              identityRequested, identityHonored}. authenticated:false
                              with status="found" is a confirmed logged-out session;
                              status="error" means the check itself could not run --
                              the binary the DETECTED forge needs is missing (gh,
                              glab or tea), or it ran and could not answer, or the
                              forge has no adapter at all. Set
                              AIMI_FORGE_IDENTITY=<login> (env var only, never a flag)
                              to compare against the active account -- this does not
                              switch accounts.
    forge-account-select (--check | --record <login> | --record-active | --reselect) [--project <path>]
                              Record, read back and revoke THIS repository's
                              remembered forge account -- the ask-once store.
                              Exactly one mode is required; giving two, or
                              none, exits 1 naming the valid modes. Reselect
                              is a FLAG on this verb, never a second verb.
                              --check reads the answer back and decides:
                              {action: "check", decision ("ask"|"skip"),
                              basis, stored, store, ...} plus every field of
                              the internal divergence verdict (forge, host,
                              activeAccount, accounts, identity, match).
                              basis is identity_override (AIMI_FORGE_IDENTITY
                              names the account, so the question is moot),
                              no_repository, no_host, answer_recorded, or the
                              divergence verdict's own basis. --check WRITES
                              NOTHING -- not the store, not the config
                              directory -- which is what keeps an agent-mode
                              or CI auto-answer applied-but-not-persisted, so
                              one CI run cannot permanently answer for every
                              human afterwards.
                              --record <login> remembers a named account;
                              --record-active remembers "always use whichever
                              account is active" as a first-class answer,
                              distinct from having no answer. An empty
                              --record value is refused, since it would be
                              indistinguishable from absent.
                              --reselect forgets this repository's answer so
                              the next --check asks again; deleting the store
                              file by hand does the same, because the answer
                              is the ONLY state -- there is no companion
                              marker to also delete.
                              The store is one JSON document per repository
                              (keyed on the repository's git common dir, so
                              every worktree shares it) holding one entry per
                              forge host. Every write is read-merge-write, so
                              recording or revoking one host never touches
                              another's entry.
                              No credential-shaped flag exists on this verb,
                              by design -- an acting identity is env-var-only
                              (AIMI_FORGE_IDENTITY / GH_TOKEN), never a flag.
    forge-repo-info [--project <path>]
                              Resolve the active forge's owner/repo via a single
                              forge-CLI call -- `gh repo view` on github, `glab
                              repo view -F json` on gitlab -- falling back to
                              parsing the git remote URL whenever that CLI is
                              unavailable or the forge has no such tier. gitea
                              always takes the fallback, by decision: tea has no
                              "show THIS repository as JSON" command to call.
                              Output: {status ("found"|"not_found"), data,
                              message}. data (when found) carries {forge, host,
                              owner, repo, nameWithOwner,
                              source ("gh"|"glab"|"local-parse")}.
    forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]
                              Field-selectable PR lookup with a three-way
                              found|not_found|error status, fixing the
                              exit-code conflation `gh pr view --json url`
                              carries today (a broken token reads as "no PR
                              yet"). Output: {status, pr, unsupported_fields,
                              message}. --include is a comma-separated
                              subset of: number, url, title, body, state,
                              headRefName, baseRefName, files, isDraft,
                              mergeable -- defaults to the portable core
                              (excludes files/isDraft/mergeable) when
                              omitted. Any other name exits 1. github,
                              gitlab and gitea each have an adapter; only
                              `unknown`, or a missing gh/glab/tea binary,
                              degrades to status=error with no stderr
                              output.
    forge-pr-create --title <t> --base <branch> --head <branch> [--body <text>] [--project <path>]
                              Write verb -- shells gh pr create (no --json
                              flag exists on it; the URL is captured and the
                              number is derived via a structured forge-pr-
                              view re-read, never a regex on the URL).
                              Idempotent: checks forge-pr-view for an
                              existing open PR on --head first and reports
                              it as status "unchanged" instead of opening a
                              duplicate. Output: {status: "created"|
                              "unchanged"|"degraded", data: {url, number},
                              message} (forge-contract.md's Write-Verb
                              Status Convention -- the same envelope
                              forge-pr-edit and forge-issue-create emit).
                              Unlike forge-issue-create, a missing
                              gh binary or an unsupported forge prints the
                              manual git-push + PR-creation instructions to
                              stderr (MANDATORY-PRINT degrade mode) and
                              EXITS NON-ZERO -- a hard failure, so a
                              caller's own per-repository failure isolation
                              can react. github, gitlab and gitea each have
                              an adapter. Identity, when needed, is read from
                              an env var (e.g. AIMI_FORGE_IDENTITY /
                              GH_TOKEN), never a flag.
    forge-pr-edit --number <n> --body <text> [--project <path>]
                              Write verb -- shells gh pr edit <number>
                              --body, then re-reads the PR via forge-pr-view
                              to confirm and report {url, number} under the
                              same write envelope forge-pr-create emits. A
                              successful edit reports status "unchanged": it
                              mutates an existing number and mints no new
                              identifier. Same guards, degrade contract, and
                              non-zero-exit-on-failure as forge-pr-create.
                              github, gitlab and gitea each have an adapter.
    forge-issue-view (--number <n> | --url <issue-url>) [--project <path>]
                              Read verb -- shells gh issue view, normalized to
                              {status: "found"|"not_found"|"error", data, message}
                              (forge-contract.md's Three-Way Status Convention).
                              data carries {number, url, title, body, state,
                              labels, comments, unsupported_fields, raw} on
                              found. QUIET degrade mode: a missing or
                              unauthenticated forge CLI yields status "error"
                              with no stderr output. github, gitlab and gitea
                              each have an adapter.
    forge-issue-create --title <t> --body <b> [--project <path>]
                              Write verb -- shells gh issue create (no --json
                              flag exists on it; the URL/number are captured
                              and derived here). Output: the same write
                              envelope the two PR write verbs emit --
                              {status: "created"|"degraded", data: {url,
                              number}, message} (forge-contract.md's
                              Write-Verb Status Convention; "unchanged"
                              never occurs here, since this verb only ever
                              mints a new issue). A
                              degraded/failed create is NEVER a hard failure
                              (exit stays 0) -- it prints a manual "create
                              this yourself" instruction to stderr
                              (MANDATORY-PRINT degrade mode) and lets the
                              caller branch on status instead. github, gitlab
                              and gitea each have an adapter.
    forge-pr-review-threads --pr <number> [--owner <owner> --repo <repo>] [--all] [--project <path>]
                              Read verb -- ports get-pr-comments' reviewThreads
                              GraphQL query verbatim; owner, repo and the PR
                              number are bound via gh api graphql's own -f/-F
                              flags, never interpolated into the query text.
                              Output: {status: "found"|"not_found"|"error",
                              data, message} (forge-contract.md's Three-Way
                              Status Convention). data carries {pr: {number,
                              title, url}, threads: [...], unsupported_fields}.
                              Each thread carries {id, isResolved, isOutdated,
                              isCollapsed, path, line, startLine, diffSide,
                              comments: {totalCount, nodes}}. Without --all,
                              threads is filtered to isResolved==false and
                              isOutdated==false, matching get-pr-comments'
                              existing filter; --all returns every thread.
                              Owner/repo auto-detected via forge-repo-info
                              when not both supplied. QUIET degrade mode: a
                              missing forge CLI, unsupported forge, or CLI
                              failure yields status=error with no stderr.
                              github, gitlab and gitea each have an adapter.
    forge-resolve-review-thread --thread-id <id> [--project <path>]
                              Write verb -- ports resolve-pr-thread's
                              resolveReviewThread GraphQL mutation verbatim;
                              the thread id is bound via gh api graphql's own
                              -f flag, never interpolated. Output: {status:
                              "found"|"error", data, message}. status="found"
                              covers both a successful resolve
                              (data.resolved=true) and a confirmed-invalid
                              thread id (data.resolved=false, the mutation
                              ran) -- both exit 0, no stderr. status="error"
                              means gh could not attempt the mutation at all
                              (missing binary, unsupported forge, or a
                              genuine gh failure) -- MANDATORY-PRINT: prints a
                              manual "resolve it yourself in the PR's Files
                              changed tab" instruction to stderr and exits
                              non-zero, since there is no gh subcommand or
                              REST fallback for resolving a review thread.
                              github, gitlab and gitea each have an adapter.
    detect-interactivity [--non-interactive]
                              Print resolved interactivity mode (picker|agent)
                              Returns picker by default; returns agent only when
                              --non-interactive is passed, AIMI_AGENT_MODE=true, or CI=true
    list-models               List available models for the current host as a JSON array.
                              Claude Code: ["opus","sonnet","haiku"].
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              stdout is always a valid JSON array; warnings go to stderr.
    resolve-models            Resolve configured model for each agent category.
                              Reads ~/.config/aimi/models.json (schema v2.0) and emits
                              a single-line JSON object with keys research, review,
                              design, workflow, executor.
                              Schema v2.0 shape: categories.<host>.<category> = model id.
                              Unconfigured or fallback entries use the literal "inherit".
                              v1.0 configs (top-level .models key or schemaVersion != "2.0")
                              are rejected with a stderr warning; all-inherit returned.
                              Warnings go to stderr; stdout is always valid JSON.
    get-current-models        Emit current per-category model assignments for the
                              active host as a JSON object with keys research, review,
                              design, workflow, executor. Unset entries emit JSON null
                              (not the string "inherit" returned by resolve-models) so
                              picker UIs can pre-select sensible defaults and distinguish
                              "not configured" from an explicit "inherit" override.
                              v1.0 configs rejected identically to resolve-models.
    detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]
                              Detect available models on the current host and write
                              ~/.config/aimi/models.json (schema v2.0).
                              Claude Code: fixed set (opus, sonnet, haiku).
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              Category flags (--research/--review/--design/--workflow/--executor):
                              non-interactive write mode — writes the given
                              category-to-model assignments directly. Preserves the
                              other host's categories sub-table when a file already exists.
                              All five category flags must be supplied together.
                              Interactive (stdin TTY, no flags): prompts per category,
                              validates answer against available-model list.
                              Non-interactive (no flags, stdin not TTY): default mapping
                              (research=fast/haiku, review=powerful/opus,
                              design+workflow+executor=balanced/sonnet).
                              Emits the written JSON on stdout.
    models-prompt-check       Check whether the model-selection prompt should be shown.
                              Per-host decision:
                              - prompt when the config file is missing entirely (always
                                re-trigger after deletion, regardless of any marker)
                              - skip when the current host (claudeCode or opencode) has
                                at least one non-null category
                              - skip when the file is present, the current host is
                                unconfigured, AND the per-host dismissal marker exists
                                (~/.config/aimi/models-prompt-seen-<host>)
                              - prompt otherwise (file present, host unconfigured, no
                                marker) — including v1.0 configs and empty/malformed files
    models-prompt-dismiss     Atomically create the per-host first-run prompt marker file
                              (~/.config/aimi/models-prompt-seen-<host> where <host> is
                              claudeCode or opencode based on CLAUDECODE). Idempotent.
                              Run after the user responds to the prompt on this host
                              (regardless of their choice) so the prompt is not re-shown
                              when the host stays unconfigured. Re-deleting models.json
                              still re-triggers the prompt — the marker only suppresses
                              when the file exists but the host has no config.
    setup-branch <name> --default-branch <branch> [--project <path>]
                              Create or checkout branch with deterministic logic
    resolve-base-branch <name> --default-branch <branch> [--base <branch>] [--project <path>]
                              Decide what branch a new branch or container should be cut
                              from -- no checkout is performed. Prints a single JSON object:
                              {"base","reason","currentBranch","defaultBranch","promptNeeded"}.
                              reason is exactly one of: explicit-base, target-exists,
                              stacked-on-current, default-branch, detached-head.
                              base prefers the origin/<name> remote-tracking ref when it
                              exists, falling back to the bare local name otherwise --
                              except for stacked-on-current, which always keeps the bare
                              local ref, since stacking exists to inherit the local tip.
                              --base "" is treated exactly like an omitted --base, so a
                              caller may pass an unset variable through unconditionally.
                              promptNeeded is true only when the target does not exist
                              (locally or on origin), the current branch is not the
                              default branch, and it is not merged into origin/<default>.
    clear-state               Clear all state files
    version                   Print the plugin version
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    list-archivable           List task files where all stories are completed/skipped (JSON array)
    archive-task <path>       Move completed task file (and linked brainstorm) to .aimi/archive/
    research-lookup [--ignore-missing-cited-paths] <path>
                              Check whether a research .md file is fresh relative to cited source
                              paths listed under its '## File References' h2 bullet section.
                              Freshness: research mtime >= newest mtime of cited source paths.
                              Fresh: prints the resolved research path, exits 0.
                              Stale/undecidable: prints nothing, exits 1.
                              Cited path not found -> stale + stderr warning.
                              --ignore-missing-cited-paths: a missing cited path logs a warning
                                but does NOT mark the file stale (mtime staleness is unaffected).
                                Use when cited sources include to-be-created files.
                              Absolute or outside-root path -> rejected (exit 1).
                              Flag accepted in either position relative to the path arg.
    extract-sections <file> --anchors "<titles>"
                              Print only the requested '## '/'### ' sections of a
                              research .md file, concatenated verbatim in request order.
                              Each section spans its matching heading up to the next
                              heading of the same-or-higher level (or EOF) -- an h2
                              anchor includes nested h3s and stops at the next h2/h1;
                              an h3 anchor stops at the next h3/h2/h1.
                              --anchors accepts comma- or newline-separated heading
                              titles; matching is case-insensitive on heading text.
                              An anchor with no matching heading is skipped (not an
                              error); anchors matching nothing -> empty output, exit 0.
                              Path confinement mirrors research-lookup (resolve_path +
                              validate_path_in_project); missing file or missing
                              <file>/--anchors arg -> error/usage on stderr, exit 1.
    research-gc               Delete orphaned .aimi/research/*.md files not referenced by any
                              active .aimi/tasks/*.json metadata.researchPaths or any
                              .aimi/brainstorms/*.md frontmatter researchPaths, AND older than
                              30 days. .aimi/archive is ignored. Silent when nothing cleaned.
    detect-design-bundle [--root <path>] [--all] [--json]
                              Detect a Claude Design handoff bundle. --root may
                              point at a bundle directory directly, or at a
                              parent dir whose immediate children include bundle
                              dirs (depth-1 scan in that case). Returns JSON
                              {path,readme,chats[],prototypes[],hasReact,
                              hasTailwind,businessSpec,designSpec} or null when
                              no bundle found.
                              --root   Scan <path> (bundle or parent) instead of CWD
                              --all    Return all matching bundles as JSON array
                              --json   Alias; output is always JSON
    bundle-prototype-status --bundle <path> --topic <slug> [--force]
                              Check whether a bundle prototype needs (re-)generation.
                              Returns JSON with keys: needs_generation (bool),
                              view_list (array of {name,source_section}),
                              view_source ('designSpec'|'businessSpec'|'none'),
                              output_path, sidecar_path.
                              view_list is extracted from DesignSpec § 4 first,
                              falling back to BusinessSpec § 5 then § 6.
                              --force  Always set needs_generation to true
    bundle-prototype-finalize --topic <slug> --bundle-hash <hex>
                              --design-spec-hash <hex> --business-spec-hash <hex>
                              --view-list <json> --source-command <brainstorm|plan>
                              Write the bundle-prototype sidecar atomically.
                              Sidecar path: .aimi/brainstorms/prototypes/<slug>-bundle-sidecar.json
                              chmod 600 applied; writes are atomic (tmp + mv).
                              --source-command must be exactly 'brainstorm' or 'plan'.
    story-merge --staging-dir <dir> --output <path>
                              [--split legacy|full-stack] [--agent-mode]
                              [--phase-aware] [--foundation <NN>]
                              Consolidate per-story staging *.json files into a
                              validated tasks.json. Steps: glob+validate JSON,
                              assign US-NNN IDs by lex order, remap outline:NN
                              tokens in dependsOn, DAG cycle detection, wave
                              computation, Rule 22 mock-sync AC routing, Phase
                              3.1 inventory verdict check, Phase 4.1 coverage
                              ratio (ac_anchors >= floor(proto_elements * 0.6)),
                              Phase 4.2 orphan-symbol smell (heuristic scan of
                              sibling-story prose for symbols a story introduces
                              that no other story references; not codebase
                              dead-code detection — always a warning, never a
                              hard block; skipped for single-story merges).
                              --split full-stack additionally detects
                              cross-file-dep-dropped smells: a dependsOn edge
                              that crosses an output-file boundary (a repo
                              boundary on the PROJECT axis, the
                              frontend/backend boundary on the SIDE axis) is
                              still dropped (each file's graph stays
                              self-contained) but is now surfaced via one
                              aggregated stderr banner plus a
                              metadata.smellWarnings entry per affected story
                              in EVERY output file the split produced (keyed by
                              .project on the PROJECT axis, .side on the SIDE
                              axis).
                              Writes atomically via _lock (tmp+mv). Deletes
                              staging dir on success; preserves on error.
                              --split full-stack picks its axis by counting
                              distinct normalized .project values (trim, strip
                              one trailing slash, blank/absent = null).
                              >= 2 -> PROJECT axis (multi-repo): one output
                              file per project, <base>-<project-slug>-tasks.json,
                              no frontend/backend decision at all; each file
                              carries metadata.splitGroup + its own branchName.
                              A multi-repo plan requires EVERY story to carry a
                              project: once any story is tagged, a project-less
                              story is refused (no files written) rather than
                              routed anywhere. A story belonging to the root
                              repository says so explicitly with "." — an absent
                              project is not the root, it is unrouteable.
                              < 2 -> SIDE axis (single-repo/monorepo, incl. no
                              .project at all): two output files,
                              <base>-frontend-tasks.json and
                              <base>-backend-tasks.json, each story classified
                              by its own file-pattern/title heuristic verdict.
                              Both axes assign unique IDs, rebuild dependsOn,
                              and recompute wave numbers per file.
                              Derived slugs/paths/branch names are length-bounded
                              and REFUSED (never truncated) when over: slug 64,
                              output basename 248, full path 4000, branchName
                              100. Truncation would manufacture a basename
                              collision between two distinct long project values.
                              --phase-aware (only meaningful with --split
                              full-stack): strip one trailing "-tasks" segment
                              from the --output basename before deriving the
                              split basenames. Pure string manipulation on the
                              basename, independent of the axis: on SIDE it
                              yields <base>-frontend-tasks.json /
                              <base>-backend-tasks.json, on PROJECT it yields
                              <base>-<project-slug>-tasks.json — in both cases
                              with a single "tasks" segment instead of the
                              doubled legacy form. Requires an --output basename
                              ending in "-tasks" with at least one character
                              before it (the phase-scoped form, e.g.
                              "<feature>-phase-<N>-tasks.json"); anything else
                              (e.g. "tasks.json") is refused up front, because
                              the strip would otherwise leave an empty or
                              "-"-leading basename. Omitted: unchanged legacy
                              derivation (double "-tasks-frontend-tasks.json").
                              --foundation <NN> two-digit 1-based outline
                              position of the shared foundation story (resolved
                              against the same outline-position map as
                              outline:NN, not a literal staging-filename digit).
                              Appends the foundation's assigned US-NNN to every
                              OTHER story's dependsOn, deduplicated, after the
                              outline:NN remap and before cycle detection and
                              wave computation, so injected edges participate in
                              both. Refuses the whole merge when the foundation
                              story's own dependsOn is non-empty. On the PROJECT
                              axis the foundation lives in exactly one group, so
                              every other group's injected edge is dropped and
                              flagged droppedDeps[].foundationEdge: true, with
                              its own stderr note separate from the ordinary
                              drop-count banner — that loss is expected fallout
                              of --foundation + multi-repo, not a hand-authored
                              dependency that went missing. The SIDE axis emits
                              no foundationEdge field.
                              --agent-mode demotes Phase 3.1 and Phase 4.1
                              hard rejects to warnings and proceeds.
    split-detect [--dir <phase-dir>]
                              Read side of metadata.splitGroup: decide whether
                              the tasks files in scope form ONE split group that
                              must execute together, and report which members
                              still have pending work. A query, never a gate —
                              every outcome, including "single" and "none",
                              exits 0; non-zero is a real error (bad argument,
                              unreadable --dir).
                              Scope. Without --dir: FLAT — *-tasks.json whose
                              parent directory is .aimi/tasks itself, depth 1
                              only. The depth restriction is load-bearing:
                              find-tasks-all globs depth 1-3, which includes
                              phase directories, so without it a phase's split
                              files are captured by the flat flow and run as a
                              flat split — the phase never gets claimed and
                              nothing merges into the phase branch. With --dir:
                              that directory's *-tasks.json, minus the phase's
                              own <feature>-phase-<N>-tasks.json.
                              Algorithm. The anchor is the NEWEST candidate by
                              mtime, not the first marker-carrying file in mtime
                              order — the latter let a stale marked split from a
                              past feature preempt today's plan whenever today's
                              files carried no marker. If the anchor carries a
                              well-formed metadata.splitGroup (total a number,
                              siblings an array), siblings resolve BY BASENAME
                              against the anchor's own directory (which renders
                              a traversal-shaped sibling entry inert) and the
                              resolved count must equal total and be >= 2.
                              A group whose members are ALL completed is dropped
                              whole from the pool and the search repeats, so a
                              finished stale split cannot route today's real work
                              to a single-file fallback. A marker present but
                              failing validation degrades and is terminal — it
                              does NOT fall through to the legacy pair, because
                              any -frontend-/-backend-tasks.json beside a
                              project-split marker is stale work. When the newest
                              candidate carries no marker, the legacy
                              -frontend-tasks.json/-backend-tasks.json pair rule
                              is tried over the pool (counterpart must be in the
                              pool, not merely on disk). Otherwise: single.
                              Pending is (.status // "pending") != "completed" —
                              one definition for every count reported, so an
                              in_progress story is pending everywhere.
                              Output. One JSON object: {mode: "project-split"|
                              "paired-split"|"single"|"none", anchor, members:
                              [{path,project,branchName,storyCount,pendingCount,
                              active}], activeCount, total, degradedReason}.
                              degradedReason explains any fall-back so the caller
                              can report it without re-deriving why.
    verify-creates --feature <slug> --phase <id> [--dir <container-path>]
                              Prove a phase's declared creates[] exist in code.
                              Prints a JSON array, one object per creates[]
                              entry: {identity, status, method, evidence,
                              gitStatus}. status is verified|missing|error;
                              method is "path" (matched a tracked path),
                              "text" (matched tracked source) or null.
                              --dir is the phase container's absolute path;
                              it defaults to the project root.
                              A query, never a gate — producing a verdict array
                              exits 0, including one where every entry is
                              missing. Non-zero is a real error only: unknown
                              flag, absent/non-numeric --phase, absent or
                              malformed roadmap.json, --dir not a directory.
                              Four steps per identity: (1) tracked path via
                              git ls-files, matching a directory as well as a
                              file; (2) strip a leading GET/POST/PUT/PATCH/
                              DELETE/HEAD/OPTIONS token so "POST /api/x" is
                              searched as "/api/x"; (3) git grep -F over
                              tracked source excluding docs and tests, bypassed
                              when the identity is itself documentation;
                              (4) drop hits that are only a TODO/FIXME/XXX/HACK
                              comment. A missing entry's evidence names the
                              rejected location and line, and states that git
                              sees tracked files only. git exiting above 1 is
                              status "error" carrying the code — never
                              "missing": a tool failure is not an absent
                              artifact.
    roadmap-init --feature <slug> [--file <path>] [--sync] [--brainstorm-path <path>]
                              Read a sanitized phases array (stdin or --file) and
                              atomically create/append to .aimi/tasks/<slug>/roadmap.json.
                              Without --sync, an existing roadmap.json is a hard error.
                              With --sync, only phases whose id is not already present
                              are appended; existing phases are left byte-for-byte
                              unchanged. Rejects (before any write) phases with a
                              missing id/name/goal, a dangling dependsOn reference,
                              or a computed dir that fails ^phase-[0-9]+(\.[0-9]+)?
                              (-[a-z0-9][a-z0-9-]*)?$. Free-text fields are sanitized
                              and length-capped per commands/references/sanitization.md.
                              Also rejects, per entry, a creates/needs IDENTITY (the
                              text before the first "(") that is empty, carries
                              whitespace, a ".." segment, a leading "/", one of
                              [$`;|&], or matches an injection pattern -- and an
                              areas[] glob that is absolute or traverses. The
                              identity is what verify-creates greps for literally;
                              the parenthesised description is judged only for
                              injection patterns and may hold the rest. Full rules
                              and rationale: commands/references/scope-contexts.md
                              section "Creates/Needs Contracts".
    roadmap-amend-phase --feature <slug> --phase <id> [--goal <text>] [--branch <name>]
                              [--file <path>] [--retarget-needs "<old>=<new>"]...
                              Correct an EXISTING phase's contract in place --
                              the one writer for a phase roadmap-init already
                              created, since --sync leaves an existing phase
                              byte-for-byte alone. Locked read-modify-write with
                              the same mktemp-then-mv atomic swap.
                              Amendable fields are exactly six: goal,
                              successCriteria, creates, needs, areas, branch.
                              They arrive as scalar flags (--goal/--branch) or as
                              a JSON object on stdin or --file; stdin is read only
                              when neither scalar flag is given. Merge is partial
                              by key presence -- a key present replaces that field
                              wholesale, a key absent leaves the stored value
                              byte-for-byte unchanged. Every other phase, the
                              document metadata, and this phase's own id, dir,
                              slug, name, dependsOn, status and claim are
                              untouched.
                              branch is amendable because nothing else writes it
                              for an existing phase (that is why a decimal phase's
                              null branch could not be filled). status and claim
                              are NOT: roadmap-set-status and roadmap-claim /
                              roadmap-release-claim already own them, and both keys
                              are rejected by name pointing at their owner.
                              Caveat: amending branch rewrites the roadmap field
                              only -- it does not move a worktree or git branch an
                              in_progress phase has already created.
                              Values pass roadmap-init's own gates: the same
                              sanitizer and caps, the same creates/needs identity
                              guard, and the same branch pattern.
                              Dropping or renaming a creates identity a later
                              phase cites in needs is REFUSED by default; the error
                              names every downstream phase and identity and prints
                              the --retarget-needs line that would authorize it.
                              --retarget-needs "<old identity>=<new identity>"
                              (repeatable, split on the first "=") authorizes it:
                              the same write replaces every matching downstream
                              needs entry with the amended phase's new creates
                              entry verbatim. Identity comparison is exact
                              equality, never substring. A pair whose old identity
                              is not actually dropped exits 1.
                              Also refused: an amendment that would duplicate a
                              creates identity another phase declares. Advisory
                              only (exit 0): a completed phase whose handoff.md
                              omits a newly introduced identity.
                              Prints {roadmap, phase, amended[], retargeted[]}.
    normalize-contracts --feature <slug>
                              Migrate a roadmap's stored creates/needs entries from
                              the 1.0 form -- one string, "identity (description)" --
                              to the 2.0 form {identity, description}, in place,
                              under the same lock and mktemp-then-mv swap every
                              other roadmap writer uses.
                              Each identity is computed by the SAME function every
                              reader used before the migration, so no identity
                              changes by a byte and no downstream needs is
                              repointed. An entry with no "(" gets description ""
                              (never null). An entry already in object form is left
                              untouched, which is what makes a second run a no-op.
                              It does not judge: a prose or whitespace-bearing
                              identity the current writer would refuse migrates
                              unchanged, and the reader reports it afterwards by
                              name. Repairing silently would change what a phase
                              promises.
                              Prints {roadmap, converted, roadmapVersion}, where
                              converted counts entries that were strings BEFORE
                              this run -- so a second run prints 0.
    roadmap-get --feature <slug> [--phase <id>] [--next-eligible]
                              Read-only. Bare: print the full roadmap.json.
                              --phase <id>: print one phase object.
                              --next-eligible: print the next claimable phase in
                              pending/planned status, unclaimed, whose dependsOn
                              phases are all completed. Ordered by remaining work
                              first and numeric id second -- a phase whose own
                              tasks file shows every story completed is reported
                              last, not first. Exits 1 if none. Does not clear
                              stale dead-PID claims (roadmap-claim does that,
                              under its lock); reads one tasks file per phase.
    roadmap-set-status --feature <slug> --phase <id> --status <status> [--force]
                              Locked read-modify-write. Enforces the guarded order
                              pending -> planned -> in_progress -> completed, plus
                              verification_failed -> completed (retry path); any
                              status may move to verification_failed. Other
                              transitions require --force. Transitioning to
                              completed always requires handoff.md to already
                              exist on disk at the phase's dir (write it first
                              with roadmap-write-handoff) -- this precondition
                              is NOT overridable by --force. A completed
                              transition also clears the phase's claim in the
                              same atomic write.
    roadmap-write-handoff --feature <slug> --phase <id> [--file <path>]
                              Read a JSON object (stdin or --file) with five
                              optional array-of-string fields -- decisions,
                              artifacts, deviations, deferred, contracts --
                              sanitize each entry, and atomically write
                              phase-<dir>/handoff.md with exactly five "## "
                              headings in that fixed order: Decisions Made,
                              Artifacts Created, Deviations, Deferred Items,
                              Contracts Delivered. This is the only path that
                              may create or overwrite that file -- direct
                              Write/Edit tool calls on it are blocked by
                              guard-runtime-state.py.
    roadmap-claim --feature <slug> --session-id <id> --session-pid <pid> [--phase <id>]
                              Atomic locked read-modify-write. Auto-releases any
                              claim whose recorded pid fails a signal-zero liveness
                              probe. Self-reclaim: if this session already owns an
                              unreleased claim on a still-active phase (matching
                              --phase when given), returns that same phase again
                              instead of erroring or re-running eligibility.
                              Without --phase: claims the next phase that is
                              pending/planned/in_progress/verification_failed,
                              unclaimed, and dependency-complete -- ordered by
                              remaining work first and numeric id second, so a
                              stuck phase with nothing left to run is demoted
                              behind any phase that still has work but is still
                              claimed once it is the only candidate. With
                              --phase <id>: claims that phase only if eligible,
                              with no ranking applied; never falls through to a
                              different phase.
                              Exit 0 with the claimed phase JSON on success.
                              Exit 3 (all-blocked / phase not claimable): pending/
                              planned phases remain but none (or the named --phase)
                              are currently claimable (stderr lists why).
                              Exit 4 (none-eligible / phase not found): no phase
                              remains pending/planned, or --phase names an id that
                              does not exist in the roadmap.
                              roadmap.json is left unmodified on exit 3 or 4.
    roadmap-release-claim --feature <slug> --phase <id>
                              Locked read-modify-write. Clears claimedBy/claimedAt/
                              claimedPid on the named phase without touching status.
                              No-op success when the phase already has no claim.
    roadmap-reconcile --feature <slug>
                              Locked read-modify-write. For each phase with an
                              existing phase-<dir>/tasks.json, derives ground-truth
                              status from userStories statuses (all completed ->
                              completed; any failed -> verification_failed; else
                              in_progress) and corrects any divergent phase status.
                              Prints {corrections:[{id,from,to}...]}.
    phase-overlap <feature> <phase-a> <phase-b>
                              Deterministic stage-2 check for the sibling-phase
                              overlap guard. Loads both phases' already-expanded
                              phase-<dir>/<feature>-phase-<id>-tasks.json files,
                              collects userStories[].implementation.files across
                              all stories in each, and prints the sorted,
                              deduplicated intersection as {"overlapping_files":[...]}.
                              Exits non-zero with a clear error (not a jq stack
                              trace) when either phase's tasks.json is missing --
                              both phases must already be rolling-wave expanded.
    estimate-payload --outline <path> [--research <path>]... [--spec <path>]...
                              [--prototype <path>]... [--budget-bytes <n>]
                              Advisory only -- never blocks, never trims content.
                              Sums the byte sizes of --outline (required) plus every
                              repeated --research/--spec/--prototype path and compares
                              against an effective budget: --budget-bytes (manual debug
                              escape hatch; no caller passes it) if given, else 50% of a
                              400000-byte reference sub-agent window.
                              Prints {totalBytes, breakdown{outline,research,specs,prototypes},
                              budgetBytes, budgetFraction, overBudget, warning}.
                              warning is null under budget; otherwise names splitting the
                              phase along a semantic seam in the roadmap or trimming scope.
                              Exits 0 for any valid input (even over budget); exits 1 only
                              when --outline is missing or a given path does not exist.
    help                      Show this help message

ENVIRONMENT:
    PROJECT_ROOT              Exported by find_aimi_root(); git repository root path
                              All file operations are validated to stay within this boundary
                              Worktree paths (.worktrees/ inside git root) are allowed

STATE FILES (.aimi/):
    current-tasks             Path to active tasks file
    current-branch            Current working branch name
    current-story             ID of story being executed
    last-result               Result of last execution (success/failed/skipped)
    default-branch            Cached default branch name (e.g., main, master)

ENVIRONMENT:
    CLAUDE_CONFIG_DIR  Override Claude config directory (default: ~/.claude)
                       Must be an absolute path when set.
    AIMI_PLUGIN_DIR    Plugin install directory set by compound-plugin converter;
                       bypasses Claude cache resolution.

EXAMPLES:
    # Resolve CLI path first (honors CLAUDE_CONFIG_DIR)
    CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    AIMI_CLI=$(ls "$CONFIG_DIR"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

    # Initialize a new session
    $AIMI_CLI init-session

    # Get next story to work on (dependency-aware)
    $AIMI_CLI next-story

    # List all ready stories (for parallel execution)
    $AIMI_CLI list-ready

    # Mark story in progress
    $AIMI_CLI mark-in-progress US-001

    # Mark story as complete
    $AIMI_CLI mark-complete US-001

    # Validate dependency graph
    $AIMI_CLI validate-deps

    # Fetch a specific story by ID
    $AIMI_CLI get-story US-003

    # Fetch story slice + metadata + skills + designContext (for subagent self-brief)
    # Output: {story, metadata, skills[{name,path,content}], designContext{decisions,bundleGuidance}}
    $AIMI_CLI get-story-context US-003

    # Cascade skip after failure
    $AIMI_CLI cascade-skip US-003

    # Check progress
    $AIMI_CLI status

    # Resume after /clear
    $AIMI_CLI get-state
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  # Skip auto-discovery for commands that don't touch .aimi/
  case "${1:-help}" in
    help|--help|-h) cmd_help; return ;;
    version) cmd_version; return ;;
    detect-interactivity) shift; cmd_detect_interactivity "$@"; return ;;
    list-models) cmd_list_models; return ;;
    resolve-models) shift; cmd_resolve_models "$@"; return ;;
    get-current-models) cmd_get_current_models; return ;;
    detect-models) shift; cmd_detect_models "$@"; return ;;
    models-prompt-check) cmd_models_prompt_check; return ;;
    models-prompt-dismiss) cmd_models_prompt_dismiss; return ;;
    prime-cache) cmd_prime_cache; return ;;
    # Forge verbs: git + an optional forge CLI + jq, and nothing else. None of
    # them reads or writes .aimi/ state, so requiring a project would be pure
    # cost -- and find_aimi_root's cd side effect is actively wrong for them:
    # in a multi-repo layout it moves the process out of the git repository the
    # caller is standing in and into the non-git .aimi/ parent. Dispatching
    # here leaves the process in the invoking CWD, which is what an omitted
    # --project must resolve to. Each verb calls check_jq itself, since the
    # one below runs too late to cover them.
    detect-forge) shift; cmd_detect_forge "$@"; return ;;
    forge-auth-status) shift; cmd_forge_auth_status "$@"; return ;;
    forge-account-select) shift; cmd_forge_account_select "$@"; return ;;
    forge-repo-info) shift; cmd_forge_repo_info "$@"; return ;;
    forge-pr-view) shift; cmd_forge_pr_view "$@"; return ;;
    forge-pr-create) shift; cmd_forge_pr_create "$@"; return ;;
    forge-pr-edit) shift; cmd_forge_pr_edit "$@"; return ;;
    forge-issue-view) shift; cmd_forge_issue_view "$@"; return ;;
    forge-issue-create) shift; cmd_forge_issue_create "$@"; return ;;
    forge-pr-review-threads) shift; cmd_forge_pr_review_threads "$@"; return ;;
    forge-resolve-review-thread) shift; cmd_forge_resolve_review_thread "$@"; return ;;
  esac

  # Universal --help/-h: any subcommand with --help or -h anywhere in its args
  # short-circuits to the top-level help doc. Runs before find_aimi_root so
  # help works outside .aimi/ projects, and before any side-effect subcommand
  # mutates state.
  for arg in "$@"; do
    case "$arg" in
      --help|-h) cmd_help; return ;;
    esac
  done

  find_aimi_root
  check_jq

  case "${1:-help}" in
    init-session)      shift; cmd_init_session "$@" ;;
    find-tasks)        cmd_find_tasks ;;
    find-tasks-all)    cmd_find_tasks_all ;;
    status)            shift; cmd_status "$@" ;;
    metadata)          cmd_metadata ;;
    next-story)        cmd_next_story ;;
    current-story)     cmd_current_story ;;
    list-ready)        shift; cmd_list_ready "$@" ;;
    mark-in-progress)  cmd_mark_in_progress "${2:-}" ;;
    mark-complete)     cmd_mark_complete "${2:-}" ;;
    mark-failed)       cmd_mark_failed "${2:-}" "${3:-}" ;;
    mark-skipped)      cmd_mark_skipped "${2:-}" ;;
    set-execution-mode) cmd_set_execution_mode "${2:-}" ;;
    count-pending)     cmd_count_pending ;;
    validate-deps)            cmd_validate_deps ;;
    validate-stories)         cmd_validate_stories ;;
    normalize-verification)   cmd_normalize_verification "${2:-}" ;;
    normalize-status)         cmd_normalize_status "${2:-}" ;;
    validate-ids)             cmd_validate_ids ;;
    gate-pass)         shift; cmd_gate_pass "$@" ;;
    gate-fail)         cmd_gate_fail "${2:-}" ;;
    update-field)      cmd_update_field "${2:-}" "${3:-}" "${4:-}" ;;
    validate-waves)    cmd_validate_waves ;;
    validate-tasks)    cmd_validate_tasks ;;
    cascade-skip)      cmd_cascade_skip "${2:-}" ;;
    reset-orphaned)    cmd_reset_orphaned ;;
    get-branch)        cmd_get_branch ;;
    get-story)         cmd_get_story "${2:-}" ;;
    get-story-context) cmd_get_story_context "${2:-}" ;;
    get-state)         cmd_get_state ;;
    detect-default-branch) shift; cmd_detect_default_branch "$@" ;;
    detect-parent-branch) shift; cmd_detect_parent_branch "$@" ;;
    # detect-forge and every forge-* verb are dispatched in the skip-list case
    # block above, before find_aimi_root -- never here.
    setup-branch)      shift; cmd_setup_branch "$@" ;;
    resolve-base-branch) shift; cmd_resolve_base_branch "$@" ;;
    clear-state)       cmd_clear_state ;;
    version)           cmd_version ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    prime-cache)       cmd_prime_cache ;;
    list-archivable)   cmd_list_archivable ;;
    archive-task)      cmd_archive_task "${2:-}" ;;
    research-lookup)   shift; cmd_research_lookup "$@" ;;
    research-gc)       cmd_research_gc ;;
    extract-sections)  shift; cmd_extract_sections "$@" ;;
    detect-design-bundle) shift; cmd_detect_design_bundle "$@" ;;
    bundle-prototype-status)   shift; cmd_bundle_prototype_status "$@" ;;
    bundle-prototype-finalize) shift; cmd_bundle_prototype_finalize "$@" ;;
    story-merge)       shift; cmd_story_merge "$@" ;;
    split-detect)      shift; cmd_split_detect "$@" ;;
    roadmap-init)          shift; cmd_roadmap_init "$@" ;;
    roadmap-amend-phase)   shift; cmd_roadmap_amend_phase "$@" ;;
    normalize-contracts)   shift; cmd_normalize_contracts "$@" ;;
    roadmap-get)           shift; cmd_roadmap_get "$@" ;;
    roadmap-set-status)    shift; cmd_roadmap_set_status "$@" ;;
    roadmap-claim)         shift; cmd_roadmap_claim "$@" ;;
    roadmap-release-claim) shift; cmd_roadmap_release_claim "$@" ;;
    roadmap-reconcile)     shift; cmd_roadmap_reconcile "$@" ;;
    roadmap-write-handoff) shift; cmd_roadmap_write_handoff "$@" ;;
    validate-contracts)    shift; cmd_validate_contracts "$@" ;;
    verify-creates)        shift; cmd_verify_creates "$@" ;;
    phase-overlap)         shift; cmd_phase_overlap "$@" ;;
    roadmap-sweep)         shift; cmd_roadmap_sweep "$@" ;;
    estimate-payload)      shift; cmd_estimate_payload "$@" ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
